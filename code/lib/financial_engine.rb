require 'date'
require 'bigdecimal'
require_relative 'dataset'
require_relative 'money'
require_relative 'exchange_rates'
require_relative 'recurrence'

# FinancialEngine implements the Stage 2 Deterministic Financial Engine:
# - Reconstructs user financial position from profiles and events
# - Incorporates pending debits (reserved)
# - Handles confirmed scheduled events
# - Uses Recurrence module to project recurring income and expenses
# - Performs conservative 90-day cash flow simulation
# - Computes amount_safe_to_pay and earliest_date_for_full_payment
# - Strictly adheres to BigDecimal financial arithmetic
#
# Stage 3 extension:
# - Accepts an optional extraction_cache (Hash of event_id => ExtractionResult)
#   produced by ImageAmountExtractor.build_cache.
# - Applies validated extracted amounts to blank-amount events BEFORE any
#   financial calculation, on a per-user shallow-dup copy of event hashes.
# - Events whose amounts remain blank after extraction are NOT silently treated
#   as zero. A warning string is emitted for each; the event is excluded from
#   calculations (pending debit reservation, scheduled cash flow, recurrence).
# - The financial engine NEVER calls a VisionProvider. The caller builds the
#   cache externally and injects it here.
module FinancialEngine
  ForecastResult = Struct.new(
    :request_id,
    :user_id,
    :request_date,
    :requested_amount,
    :start_balance,
    :min_balance,
    :amount_safe_to_pay,
    :affordability_status,
    :earliest_date_for_full_payment,
    :daily_balances,
    :recurring_streams,
    :extraction_warnings,   # Array<String> — one entry per unresolved blank-amount event
    keyword_init: true
  )

  # Runs the 90-day safety forecast for a given request.
  #
  # extraction_cache — Hash of event_id (String) => ImageAmountExtractor::ExtractionResult.
  #   Pass {} (the default) to get identical Stage 2 behaviour with no extraction.
  def self.evaluate_request(request, profile, events, extraction_cache: {})
    user_id = request['user_id']
    req_date = Date.parse(request['request_date'])
    req_amt = Money.parse(request['requested_amount'])
    home_curr = profile['home_currency']
    min_bal = Money.parse(profile['minimum_balance_to_keep'])
    start_bal = Money.parse(profile['current_available_balance'])

    user_events = events.select { |e| e['user_id'] == user_id }

    # Stage 3: Apply extracted amounts from the injection cache.
    # Work on shallow-dup copies so the global events array is never mutated.
    # Unresolved events (extraction failed or no cache entry) are excluded from
    # calculations rather than silently treated as zero.
    extraction_warnings = []
    user_events = user_events.map do |e|
      next e unless e['amount'].nil?                     # already has an amount

      result = extraction_cache[e['event_id']]

      if result.nil?
        # No extraction was attempted for this event (no cache entry).
        # Exclude safely and warn.
        extraction_warnings << "event_id=#{e['event_id']}: amount is blank and " \
                               'no extraction result in cache — event excluded from calculations'
        nil
      elsif result.success
        # Replace nil amount with validated BigDecimal expressed as a plain
        # decimal string so Money.parse handles it identically to CSV data.
        duped = e.dup
        duped['amount']   = result.amount.to_s('F')   # e.g. "4365000.0"
        duped['currency'] = result.currency if result.currency
        duped
      else
        # Extraction was attempted but failed validation.
        extraction_warnings << "event_id=#{e['event_id']}: image extraction failed " \
                               "(#{result.error}) — event excluded from calculations"
        nil
      end
    end.compact

    # Reserve pending debits (must not count pending credits/refunds)
    pending_debits = user_events.select do |e|
      e['status'] == 'pending' &&
        (e['direction'] == 'debit' || e['event_type'] == 'expense')
    end

    net_start_balance = start_bal
    pending_debits.each do |pd|
      amt = Money.parse(pd['amount'])
      if pd['currency'] && pd['currency'] != home_curr
        amt = ExchangeRates.convert(amt, pd['currency'], home_curr, Date.parse(pd['event_date']))
      end
      net_start_balance -= amt
    end

    # Scheduled events on or after request_date
    sched_events = user_events.select do |e|
      e['status'] == 'scheduled' && Date.parse(e['event_date']) >= req_date
    end

    # Recurrence streams
    streams = Recurrence.detect(user_id, req_date, user_events, profile)

    # Build daily net cash flows for the 90-day window [req_date, req_date + 90]
    daily_flow = Hash.new(Money::ZERO)

    # Add scheduled events to daily flow
    sched_events.each do |se|
      d = Date.parse(se['event_date'])
      next if d > req_date + 90

      amt = Money.parse(se['amount'])
      if se['currency'] && se['currency'] != home_curr
        amt = ExchangeRates.convert(amt, se['currency'], home_curr, d)
      end

      if se['direction'] == 'credit' || se['event_type'] == 'income'
        daily_flow[d] += amt
      else
        daily_flow[d] -= amt
      end
    end

    # Add recurring streams across the 90 days
    (0..90).each do |offset|
      d = req_date + offset

      streams.each do |s|
        applies = false

        if s.cadence == :monthly
          # Monthly recurrence on s.day_of_month
          max_day = Date.new(d.year, d.month, -1).day
          target_day = [s.day_of_month, max_day].min
          applies = (d.day == target_day)
        elsif s.cadence == :interval
          # Interval recurrence
          days_diff = (d - s.anchor_date).to_i
          applies = (days_diff > 0 && days_diff % s.interval_days == 0)
        end

        if applies
          # Do not double-count if an explicit scheduled event already exists for this category on this date
          has_sched = sched_events.any? do |se|
            Date.parse(se['event_date']) == d && se['category'] == s.category
          end

          unless has_sched
            amt = s.amount
            if s.currency && s.currency != home_curr
              amt = ExchangeRates.convert(amt, s.currency, home_curr, d)
            end

            if s.is_income
              daily_flow[d] += amt
            else
              daily_flow[d] -= amt
            end
          end
        end
      end
    end

    # Simulate daily balances
    daily_balances = {}
    current_bal = net_start_balance
    min_projected_bal = current_bal

    (0..90).each do |offset|
      d = req_date + offset
      current_bal += daily_flow[d]
      daily_balances[d] = current_bal
      min_projected_bal = current_bal if current_bal < min_projected_bal
    end

    # amount_safe_to_pay: maximum amount safe to pay today before optional spending changes
    # while maintaining minimum_balance_to_keep on every day of the 90-day forecast.
    # Capped at requested_amount, and >= 0.
    raw_safe = min_projected_bal - min_bal
    amount_safe_to_pay = if raw_safe <= Money::ZERO
                           Money::ZERO
                         elsif raw_safe >= req_amt
                           req_amt
                         else
                           Money.round(raw_safe)
                         end

    # earliest_date_for_full_payment:
    # First date d in [0, 90] where paying req_amt on date d ensures that for all t >= d,
    # projected balance - req_amt >= min_bal.
    earliest_date = nil
    (0..90).each do |offset|
      d = req_date + offset
      # Check if paying req_amt on date d maintains >= min_bal for all remaining days
      safe_from_d = (offset..90).all? do |t|
        target_d = req_date + t
        daily_balances[target_d] - req_amt >= min_bal
      end

      if safe_from_d
        earliest_date = d
        break
      end
    end

    affordability_status = determine_affordability_status(
      request, profile, amount_safe_to_pay, earliest_date
    )

    ForecastResult.new(
      request_id: request['request_id'],
      user_id: user_id,
      request_date: req_date,
      requested_amount: req_amt,
      start_balance: start_bal,
      min_balance: min_bal,
      amount_safe_to_pay: amount_safe_to_pay,
      affordability_status: affordability_status,
      earliest_date_for_full_payment: earliest_date,
      daily_balances: daily_balances,
      recurring_streams: streams,
      extraction_warnings: extraction_warnings
    )
  end

  # Determines affordability_status from financial capacity and profile preferences:
  # - affordable_now: full amount is safe on request_date and user accepts full_payment
  # - affordable_with_plan: verified valid path to complete request safely (in Stage 4,
  #     verified partial payment where allows_partial, user accepts partial_payment,
  #     0 < amount_safe_to_pay < requested_amount, and earliest_date_for_full_payment <= desired_completion_date)
  # - affordable_later: full amount is expected to become safe later (on or before desired_completion_date).
  #     Note: whether user accepts full_payment governs recommendation of 'wait' in Stage 5,
  #     not the underlying affordability_status.
  # - not_affordable: full payment cannot safely complete the request by desired_completion_date
  #     and no verified plan exists at Stage 4.
  #     (Stage 5 will evaluate seller installment options and spending changes to discover plans).
  def self.determine_affordability_status(request, profile, amount_safe_to_pay, earliest_date)
    req_amt = Money.parse(request['requested_amount'])
    req_date = Date.parse(request['request_date'].to_s)
    desired_raw = request['desired_completion_date']
    desired_date = (desired_raw && !desired_raw.to_s.strip.empty?) ? Date.parse(desired_raw.to_s) : nil

    considered_methods = (profile['payment_methods_user_will_consider'] || '')
      .split('|')
      .map(&:strip)

    allows_partial = request['allows_partial_payment'].to_s.strip.downcase == 'true'

    # 1. affordable_now: full amount is safe to pay on request_date AND user accepts full_payment
    if amount_safe_to_pay >= req_amt && considered_methods.include?('full_payment')
      'affordable_now'

    # 2. affordable_with_plan: only when an actual verified plan path exists at Stage 4.
    #    Partial payment is verified if permitted, accepted, 0 < safe < requested, and completes by deadline.
    elsif allows_partial &&
          considered_methods.include?('partial_payment') &&
          amount_safe_to_pay > Money::ZERO &&
          amount_safe_to_pay < req_amt &&
          !earliest_date.nil? &&
          (desired_date.nil? || earliest_date <= desired_date)
      'affordable_with_plan'

    # 3. affordable_later: the full amount is expected to become safe later
    #    (on or before desired completion date).
    #    Separated from payment method preference (which governs 'wait' in Stage 5).
    elsif !earliest_date.nil? && earliest_date > req_date && (desired_date.nil? || earliest_date <= desired_date)
      'affordable_later'

    # 4. not_affordable: no safe full payment or verified plan path exists within deadline at Stage 4.
    else
      'not_affordable'
    end
  end
end
