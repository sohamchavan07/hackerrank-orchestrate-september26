# frozen_string_literal: true

require 'date'
require 'bigdecimal'
require_relative 'money'

# PaymentPlanner — Stage 5: Payment method eligibility + payment plan selection.
#
# Given a ForecastResult (from FinancialEngine) and the available seller payment
# options for the request, this module selects the best safe payment plan.
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
#   3. Minimize total_amount_paid
#   4. Earlier start_date
#   5. Fewer payments
#   6. Lowest payment_option_id
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
    requires_spending_changes: false
  ).freeze

  # Main entry point.
  # Returns Hash: { recommended_payment_method:, payment_plan:, affordability_status: }
  def self.select_plan(request, profile, forecast, payment_options)
    req_date   = forecast.request_date
    req_amt    = forecast.requested_amount
    min_bal    = forecast.min_balance
    daily_bals = forecast.daily_balances
    safe_amt   = forecast.amount_safe_to_pay
    earliest   = forecast.earliest_date_for_full_payment

    desired_raw  = request['desired_completion_date']
    desired_date = (desired_raw && !desired_raw.strip.empty?) ? Date.parse(desired_raw) : nil

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
          requires_spending_changes: false
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
            requires_spending_changes: false
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
        requires_spending_changes: false
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
        requires_spending_changes: false
      )
    end

    best = rank_plans(candidates, desired_date) || NOT_RECOMMENDED_PLAN

    updated_status = case best.payment_method
                     when 'full_payment'    then 'affordable_now'
                     when 'installments', 'partial_payment' then 'affordable_with_plan'
                     when 'wait'            then 'affordable_later'
                     else forecast.affordability_status
                     end

    {
      recommended_payment_method: best.payment_method,
      payment_plan: best.payment_plan_string,
      affordability_status: updated_status
    }
  end

  # Rank candidates by spec priority and return the best.
  def self.rank_plans(candidates, desired_date)
    return nil if candidates.empty?

    on_time = desired_date ? candidates.select { |c| c.completion_date && c.completion_date <= desired_date } : candidates
    pool = on_time.empty? ? candidates : on_time

    pool.min_by do |c|
      [
        c.requires_spending_changes ? 1 : 0,
        c.total_amount_paid,
        c.start_date || Date.new(9999, 12, 31),
        c.number_of_payments,
        c.payment_option_id || 'zzzzz'
      ]
    end
  end
  private_class_method :rank_plans

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
