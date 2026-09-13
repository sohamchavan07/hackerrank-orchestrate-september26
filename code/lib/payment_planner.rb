# frozen_string_literal: true

require 'date'
require 'bigdecimal'
require_relative 'money'
require_relative 'spending_changes'

# PaymentPlanner — Stage 5 & 7: Payment method eligibility + payment plan selection + spending changes.
#
# Given a ForecastResult (from FinancialEngine) and the available seller payment
# options for the request, this module selects the best safe payment plan.
#
# When a safe on-time plan cannot be achieved with baseline finances, deterministic
# spending changes (stopping/reducing flexible recurring expenses) are evaluated
# to discover an affordable plan by the deadline.
#
# ELIGIBLE METHODS (all checked):
#   full_payment    — user considers it AND full amount is safe today
#   installments    — user considers it AND max_installment_months set AND
#                     an option with number_of_payments <= max_installment_months
#                     passes a 90-day safety check
#   partial_payment — user considers it AND allows_partial_payment AND
#                     0 < safe_amt < req_amt AND earliest within desired_date
#   wait            — user considers full_payment AND earliest > req_date
#   not_recommended — fallback when nothing else is safe/eligible
#
# RANKING (spec priority order):
#   1. Completes by desired_completion_date
#   2. No spending changes
#   3. Fewer spending changes (if spending changes required)
#   4. Minimize amount reduced/stopped (preserve more spending)
#   5. Minimize total_amount_paid
#   6. Earlier start_date
#   7. Fewer payments
#   8. Lowest payment_option_id / deterministic string tie-breaker
module PaymentPlanner
  PlanCandidate = Struct.new(
    :payment_method,
    :payment_option_id,
    :payment_plan_string,
    :schedule,
    :total_amount_paid,
    :start_date,
    :completion_date,
    :number_of_payments,
    :requires_spending_changes,
    :spending_changes,
    :spending_changes_count,
    :total_reduction,
    :spending_changes_string,
    :amount_safe_to_pay,
    :earliest_date_for_full_payment,
    keyword_init: true
  )

  NOT_RECOMMENDED_PLAN = PlanCandidate.new(
    payment_method: 'not_recommended',
    payment_option_id: nil,
    payment_plan_string: 'none',
    schedule: [],
    total_amount_paid: Money::ZERO,
    start_date: nil,
    completion_date: nil,
    number_of_payments: 0,
    requires_spending_changes: false,
    spending_changes: [],
    spending_changes_count: 0,
    total_reduction: Money::ZERO,
    spending_changes_string: 'none'
  ).freeze

  # Main entry point.
  # Returns Hash:
  #   {
  #     recommended_payment_method:,
  #     payment_plan:,
  #     affordability_status:,
  #     spending_changes_needed:
  #   }
  def self.select_plan(request, profile, forecast, payment_options, events: [], extraction_cache: {}, message_facts: [])
    desired_raw  = request['desired_completion_date']
    desired_date = (desired_raw && !desired_raw.to_s.strip.empty?) ? Date.parse(desired_raw) : nil

    # 1. Baseline candidates (no spending changes)
    baseline_candidates = generate_plan_candidates(
      request, profile, forecast, payment_options,
      requires_spending_changes: false,
      spending_changes: [],
      spending_changes_count: 0,
      total_reduction: Money::ZERO,
      spending_changes_string: 'none'
    )

    best_baseline = rank_plans(baseline_candidates, desired_date)

    # If an on-time baseline plan exists, or a safe baseline plan exists when no deadline is set,
    # it always wins by Priority 2 ("Require no spending changes").
    if best_baseline
      is_on_time = desired_date ? (best_baseline.completion_date && best_baseline.completion_date <= desired_date) : true
      if is_on_time && best_baseline.payment_method != 'not_recommended'
        return format_result(best_baseline, forecast)
      end
    end

    # 2. Evaluate spending change candidates
    # Retrieve user events for checking flexibility
    user_id = profile['user_id']
    u_events = events.select { |e| e['user_id'] == user_id }
    if u_events.empty? && defined?(Dataset)
      u_events = Dataset.load(:financial_events).select { |e| e['user_id'] == user_id } rescue []
    end

    spending_candidates = []
    if u_events.any? && forecast.recurring_streams && !forecast.recurring_streams.empty?
      eligible = SpendingChanges.find_eligible_changes(profile, forecast.recurring_streams, u_events)
      combinations = SpendingChanges.generate_combinations(eligible, 3)

      combinations.each do |comb|
        modified_streams = SpendingChanges.apply_changes(forecast.recurring_streams, comb)
        sub_fc = FinancialEngine.evaluate_request(
          request, profile, events,
          extraction_cache: extraction_cache,
          message_facts: message_facts,
          recurring_streams_override: modified_streams
        )

        comb_str = SpendingChanges.format_changes(comb)
        tot_red  = comb.sum(&:saving)

        candidates_for_comb = generate_plan_candidates(
          request, profile, sub_fc, payment_options,
          requires_spending_changes: true,
          spending_changes: comb,
          spending_changes_count: comb.size,
          total_reduction: tot_red,
          spending_changes_string: comb_str
        )

        spending_candidates.concat(candidates_for_comb)
      end
    end

    # 3. Combine and rank all candidates
    all_candidates = baseline_candidates + spending_candidates
    best = rank_plans(all_candidates, desired_date) || best_baseline || NOT_RECOMMENDED_PLAN

    format_result(best, forecast)
  end

  # Generates plan candidates for a specific forecast (baseline or modified by spending changes).
  def self.generate_plan_candidates(request, profile, forecast, payment_options,
                                   requires_spending_changes:,
                                   spending_changes:,
                                   spending_changes_count:,
                                   total_reduction:,
                                   spending_changes_string:)
    req_date   = forecast.request_date
    req_amt    = forecast.requested_amount
    min_bal    = forecast.min_balance
    daily_bals = forecast.daily_balances
    safe_amt   = forecast.amount_safe_to_pay
    earliest   = forecast.earliest_date_for_full_payment

    desired_raw  = request['desired_completion_date']
    desired_date = (desired_raw && !desired_raw.to_s.strip.empty?) ? Date.parse(desired_raw) : nil

    allows_partial = request['allows_partial_payment'].to_s.strip.downcase == 'true'

    considered = (profile['payment_methods_user_will_consider'] || '')
                   .split('|').map(&:strip)

    max_months_raw = profile['max_installment_months']
    max_months = (max_months_raw && !max_months_raw.to_s.strip.empty?) ? max_months_raw.to_i : nil

    candidates = []

    # 1. full_payment
    if considered.include?('full_payment') && safe_amt >= req_amt
      full_opt = payment_options.find { |o| o['payment_method'] == 'full_payment' }
      if full_opt
        d = Date.parse(full_opt['first_payment_date'])
        amt_str = format_amount(req_amt)
        candidates << PlanCandidate.new(
          payment_method: 'full_payment',
          payment_option_id: full_opt['payment_option_id'],
          payment_plan_string: "#{d}:#{amt_str}",
          schedule: [{ date: d, amount: req_amt }],
          total_amount_paid: req_amt,
          start_date: d,
          completion_date: d,
          number_of_payments: 1,
          requires_spending_changes: requires_spending_changes,
          spending_changes: spending_changes,
          spending_changes_count: spending_changes_count,
          total_reduction: total_reduction,
          spending_changes_string: spending_changes_string,
          amount_safe_to_pay: safe_amt,
          earliest_date_for_full_payment: earliest
        )
      end
    end

    # 2. installments
    if considered.include?('installments') && !max_months.nil?
      payment_options
        .select { |o| o['payment_method'] == 'installments' && o['number_of_payments'].to_i <= max_months }
        .each do |opt|
          n           = opt['number_of_payments'].to_i
          freq        = opt['payment_frequency_days'].to_i
          first_date  = Date.parse(opt['first_payment_date'])
          pmt_str     = opt['payment_amount']
          pmt_amt     = Money.parse(pmt_str)
          total_amt   = Money.parse(opt['total_payable_amount'])

          schedule = (0...n).map { |i| { date: first_date + (i * freq), amount: pmt_amt } }
          completion = schedule.last[:date]

          next unless installment_safe?(schedule, req_date, daily_bals, min_bal)

          plan_str = schedule.map { |p| "#{p[:date]}:#{pmt_str}" }.join('|')

          candidates << PlanCandidate.new(
            payment_method: 'installments',
            payment_option_id: opt['payment_option_id'],
            payment_plan_string: plan_str,
            schedule: schedule,
            total_amount_paid: total_amt,
            start_date: first_date,
            completion_date: completion,
            number_of_payments: n,
            requires_spending_changes: requires_spending_changes,
            spending_changes: spending_changes,
            spending_changes_count: spending_changes_count,
            total_reduction: total_reduction,
            spending_changes_string: spending_changes_string,
            amount_safe_to_pay: safe_amt,
            earliest_date_for_full_payment: earliest
          )
        end
    end

    # 3. partial_payment
    if considered.include?('partial_payment') &&
       allows_partial &&
       safe_amt > Money::ZERO &&
       safe_amt < req_amt &&
       !earliest.nil? &&
       (desired_date.nil? || earliest <= desired_date)

      second_amt = req_amt - safe_amt
      first_str  = format_amount(safe_amt)
      second_str = format_amount(second_amt)
      plan_str   = "#{req_date}:#{first_str}|#{earliest}:#{second_str}"

      candidates << PlanCandidate.new(
        payment_method: 'partial_payment',
        payment_option_id: nil,
        payment_plan_string: plan_str,
        schedule: [{ date: req_date, amount: safe_amt }, { date: earliest, amount: second_amt }],
        total_amount_paid: req_amt,
        start_date: req_date,
        completion_date: earliest,
        number_of_payments: 2,
        requires_spending_changes: requires_spending_changes,
        spending_changes: spending_changes,
        spending_changes_count: spending_changes_count,
        total_reduction: total_reduction,
        spending_changes_string: spending_changes_string,
        amount_safe_to_pay: safe_amt,
        earliest_date_for_full_payment: earliest
      )
    end

    # 4. wait
    if considered.include?('full_payment') && !earliest.nil? && earliest > req_date
      amt_str  = format_amount(req_amt)
      plan_str = "#{earliest}:#{amt_str}"

      candidates << PlanCandidate.new(
        payment_method: 'wait',
        payment_option_id: nil,
        payment_plan_string: plan_str,
        schedule: [{ date: earliest, amount: req_amt }],
        total_amount_paid: req_amt,
        start_date: earliest,
        completion_date: earliest,
        number_of_payments: 1,
        requires_spending_changes: requires_spending_changes,
        spending_changes: spending_changes,
        spending_changes_count: spending_changes_count,
        total_reduction: total_reduction,
        spending_changes_string: spending_changes_string,
        amount_safe_to_pay: safe_amt,
        earliest_date_for_full_payment: earliest
      )
    end

    candidates
  end
  private_class_method :generate_plan_candidates

  # Rank candidates by spec priority and return the best.
  def self.rank_plans(candidates, desired_date)
    return nil if candidates.empty?

    on_time = desired_date ? candidates.select { |c| c.completion_date && c.completion_date <= desired_date } : candidates
    pool = on_time.empty? ? candidates : on_time

    pool.min_by do |c|
      [
        c.requires_spending_changes ? 1 : 0,
        c.spending_changes_count || 0,
        c.total_reduction || Money::ZERO,
        c.total_amount_paid,
        c.start_date || Date.new(9999, 12, 31),
        c.number_of_payments,
        c.payment_option_id || 'zzzzz',
        c.spending_changes_string || ''
      ]
    end
  end
  private_class_method :rank_plans

  # Returns formatted result hash.
  def self.format_result(best, forecast)
    updated_status = if best.requires_spending_changes
                       'affordable_with_plan'
                     else
                       case best.payment_method
                       when 'full_payment'    then 'affordable_now'
                       when 'installments', 'partial_payment' then 'affordable_with_plan'
                       when 'wait'            then 'affordable_later'
                       else best.payment_method == 'not_recommended' ? 'not_affordable' : forecast.affordability_status
                       end
                     end

    {
      recommended_payment_method: best.payment_method,
      payment_plan: best.payment_plan_string,
      affordability_status: updated_status,
      spending_changes_needed: best.spending_changes_string || 'none',
      amount_safe_to_pay: best.amount_safe_to_pay || Money::ZERO,
      earliest_date_for_full_payment: best.earliest_date_for_full_payment
    }
  end
  private_class_method :format_result

  # Returns true when paying the cumulative installment amounts never takes
  # any projected daily balance below minimum_balance_to_keep.
  def self.installment_safe?(schedule, req_date, daily_balances, min_bal)
    (0..90).all? do |offset|
      d   = req_date + offset
      bal = daily_balances[d]
      next true if bal.nil?

      cum_paid = schedule
                   .select { |p| p[:date] <= d }
                   .reduce(Money::ZERO) { |sum, p| sum + p[:amount] }

      (bal - cum_paid) >= min_bal
    end
  end
  private_class_method :installment_safe?

  # Clean BigDecimal to decimal string, strip trailing zeros/dot.
  def self.format_amount(bd)
    s = bd.to_s('F')
    s.sub(/\.?0+$/, '')
  end
  private_class_method :format_amount
end
