# frozen_string_literal: true

require_relative 'money'
require_relative 'spending_changes'

# DecisionExplanation — Stage 9: deterministic explanation generator.
#
# Summarises the deterministic engine/planner result without overriding it.
# No LLM is used.
module DecisionExplanation
  def self.generate(request, profile, forecast, plan_result)
    currency = profile['home_currency'].to_s
    req_amt  = forecast.requested_amount
    safe_amt = forecast.amount_safe_to_pay
    method   = plan_result[:recommended_payment_method]
    status   = plan_result[:affordability_status]
    plan     = plan_result[:payment_plan].to_s
    sc       = plan_result[:spending_changes_needed].to_s
    earliest = forecast.earliest_date_for_full_payment

    parts = []
    parts << "Requested #{format_money(req_amt, currency)}."
    parts << "Safe to pay today: #{format_money(safe_amt, currency)}."

    case status
    when 'affordable_now'
      parts << 'The full amount is affordable today without spending changes.'
    when 'affordable_with_plan'
      parts << affordability_with_plan_reason(method, plan, currency)
    when 'affordable_later'
      parts << later_reason(earliest, req_amt, currency, method)
    when 'not_affordable'
      parts << 'No safe way to complete this request by the deadline was found.'
    end

    if method == 'partial_payment' && plan != 'none'
      parts << "Partial plan: #{plan.tr('|', ', ')}."
    elsif method == 'installments' && plan != 'none'
      parts << "Installment plan: #{plan.tr('|', ', ')}."
    elsif method == 'wait' && earliest
      parts << "Earliest safe full payment: #{earliest}."
    end

    if sc != 'none' && !sc.strip.empty?
      parts << "Spending changes needed: #{sc.tr('|', ', ')}."
    end

    parts.compact.join(' ')
  end

  def self.affordability_with_plan_reason(method, plan, currency)
    case method
    when 'installments'
      'Installments fit within the 90-day balance forecast.'
    when 'partial_payment'
      'A two-payment partial plan completes the request safely.'
    when 'full_payment'
      'Full payment is safe after adjusting flexible spending.'
    else
      'A payment plan completes the request safely.'
    end
  end
  private_class_method :affordability_with_plan_reason

  def self.later_reason(earliest, req_amt, currency, method)
    if earliest
      "Full payment of #{format_money(req_amt, currency)} is expected to be safe from #{earliest}."
    else
      'Full payment is not safe today but may become affordable later.'
    end
  end
  private_class_method :later_reason

  def self.format_money(amount, currency)
    "#{currency} #{format_amount(amount)}"
  end
  private_class_method :format_money

  def self.format_amount(bd)
    if bd == bd.to_i
      bd.to_i.to_s
    else
      s = bd.to_s('F')
      s.sub(/\.?0+$/, '')
    end
  end
  private_class_method :format_amount
end
