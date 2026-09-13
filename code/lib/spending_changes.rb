# frozen_string_literal: true

require 'date'
require 'bigdecimal'
require_relative 'money'

# SpendingChanges — Stage 7: Deterministic spending changes logic.
#
# Only flexible recurring expenses may be changed.
# For a given recurring expense, stop and reduce_to are mutually exclusive.
# At most 3 spending changes may be proposed.
#
# Format:
#   stop:event_id
#   reduce_to:event_id:new_amount
#
# Rules:
# 1. Essential, protected, fixed, or one-off transactions cannot be changed.
# 2. Reduction amount must be strictly lower than existing recurring amount and > 0.
# 3. All event_ids and minimum amounts come authoritatively from financial_events.csv.
module SpendingChanges
  Change = Struct.new(
    :action,      # :stop or :reduce
    :event_id,    # String: event_id of the flexible recurring stream
    :stream,      # Recurrence::RecurringStream
    :new_amount,  # BigDecimal: Money::ZERO for stop, minimum_allowed_amount for reduce
    :saving,      # BigDecimal: amount saved per occurrence
    :string,      # String: e.g. "stop:event_14" or "reduce_to:event_21:100"
    keyword_init: true
  )

  # Finds all eligible atomic spending changes for the user's active recurring streams.
  def self.find_eligible_changes(profile, recurring_streams, user_events)
    protect     = (profile['expense_categories_to_protect'] || '').split('|').map(&:strip)
    reduce_cats = (profile['expense_categories_user_is_willing_to_reduce'] || '').split('|').map(&:strip)
    stop_cats   = (profile['expense_categories_user_is_willing_to_stop'] || '').split('|').map(&:strip)

    eligible = []

    recurring_streams.each do |stream|
      next if stream.is_income
      next if stream.last_event_id.nil? || stream.last_event_id.to_s.strip.empty?
      next if protect.include?(stream.category)

      ev = user_events.find { |e| e['event_id'] == stream.last_event_id }
      next unless ev

      flex = ev['flexibility'].to_s.strip
      next if flex == 'fixed' || flex.empty?

      # 1. Check STOP eligibility
      can_stop = (flex == 'stoppable' || flex == 'reducible_or_stoppable') && stop_cats.include?(stream.category)
      if can_stop
        eligible << Change.new(
          action: :stop,
          event_id: stream.last_event_id,
          stream: stream,
          new_amount: Money::ZERO,
          saving: stream.amount,
          string: "stop:#{stream.last_event_id}"
        )
      end

      # 2. Check REDUCE eligibility
      can_reduce = (flex == 'reducible' || flex == 'reducible_or_stoppable') && reduce_cats.include?(stream.category)
      min_raw = ev['minimum_allowed_amount']
      if can_reduce && min_raw && !min_raw.to_s.strip.empty?
        min_amt = Money.parse(min_raw)
        # Spec rule: new_amount must be positive and strictly lower than existing recurring amount
        if min_amt > Money::ZERO && min_amt < stream.amount
          formatted_min = format_amount(min_amt)
          eligible << Change.new(
            action: :reduce,
            event_id: stream.last_event_id,
            stream: stream,
            new_amount: min_amt,
            saving: stream.amount - min_amt,
            string: "reduce_to:#{stream.last_event_id}:#{formatted_min}"
          )
        end
      end
    end

    # Deterministic sort of eligible changes: by event_id, then action (:stop before :reduce)
    eligible.sort_by { |c| [c.event_id, c.action == :stop ? 0 : 1] }
  end

  # Generates valid candidate combinations of spending changes (up to max_changes = 3).
  # Mutual exclusivity: a given event_id cannot appear more than once in any combination.
  def self.generate_combinations(eligible_changes, max_changes = 3)
    return [] if eligible_changes.empty?

    combinations = []
    limit = [max_changes, eligible_changes.size].min

    (1..limit).each do |k|
      eligible_changes.combination(k).each do |comb|
        # Enforce mutual exclusivity: distinct event_ids
        event_ids = comb.map(&:event_id)
        next if event_ids.uniq.size != comb.size

        combinations << comb
      end
    end

    combinations
  end

  # Applies a combination of changes to an array of recurring streams,
  # returning a new array of modified streams.
  def self.apply_changes(streams, combination)
    streams.map do |s|
      change = combination.find { |c| c.event_id == s.last_event_id }
      if change
        if change.action == :stop
          nil # stream is removed from forecast
        else
          duped = s.dup
          duped.amount = change.new_amount
          duped
        end
      else
        s
      end
    end.compact
  end

  # Formats a combination of changes into the canonical output string
  # (e.g. "stop:event_1815|reduce_to:event_1816:23.50"), sorted by event_id.
  def self.format_changes(combination)
    return 'none' if combination.nil? || combination.empty?

    combination.sort_by(&:event_id).map(&:string).join('|')
  end

  # Formats an amount: whole numbers without decimals (e.g. 665950),
  # decimals formatted to 2 decimal places (e.g. 23.50).
  def self.format_amount(bd)
    if bd == bd.to_i
      bd.to_i.to_s
    else
      sprintf('%.2f', bd)
    end
  end
end
