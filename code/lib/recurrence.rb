require 'date'
require 'bigdecimal'
require_relative 'money'
require_relative 'exchange_rates'

# RecurrenceDetector identifies genuine recurring income and expense streams
# from financial events, strictly distinguishing genuine ongoing commitments
# from sporadic or one-off transactions.
#
# Rules:
# 1. Salary Continuation (Bug 1 fix):
#    - If an explicit `scheduled` salary event exists on or after request_date,
#      it is confirmed future income and continues monthly at that amount.
#    - Does not require multiple historical salary occurrences when confirmed
#      scheduled salary information is present (handles prorated first salary,
#      new jobs, and transition periods).
#    - If no scheduled salary exists, checks settled salary history:
#      * Continues if standard ongoing employment ("Payroll credit", "Base salary", etc.).
#      * Does NOT continue if employment has ended ("Final employer payroll") or
#        if temporary/seasonal assignment has expired.
#
# 2. Strict Evidence for Recurrence (Bug 2 fix):
#    - A single observed interval (exactly 2 occurrences) is NEVER sufficient
#      by itself to establish recurrence for general transactions.
#    - A 2-occurrence series is only recurring if supported by:
#      a) An explicit `scheduled` future occurrence, OR
#      b) Explicit subscription semantics (`event_type == 'subscription'`).
#    - General recurring expenses require at least 3 occurrences (at least 2
#      consecutive intervals) with consistent cadence.
#    - Variable everyday spending (`groceries`, `transport`, `dining`) is analyzed
#      at the category level, preventing sporadic memos (such as "Fuel refill")
#      from falsely spawning independent recurring series.
module Recurrence
  RecurringStream = Struct.new(
    :name,
    :category,
    :event_type,
    :amount,
    :currency,
    :cadence,       # :monthly, :weekly, :biweekly, etc.
    :day_of_month,  # for monthly streams (1..31)
    :interval_days, # for day-interval streams
    :anchor_date,   # Date
    :last_event_id,
    :is_income,
    keyword_init: true
  )

  # Detects recurring streams for a given user up to/at request_date
  def self.detect(user_id, request_date, events, profile)
    user_events = events.select { |e| e['user_id'] == user_id && !e['amount'].nil? && !e['amount'].to_s.strip.empty? }
    streams = []

    # 1. Detect salary income stream
    salary_stream = detect_salary(user_events, request_date, profile)
    streams << salary_stream if salary_stream

    # 2. Detect subscription streams (explicit subscription semantics)
    subscription_streams = detect_subscriptions(user_events, request_date)
    streams.concat(subscription_streams)

    # 3. Detect fixed recurring commitments (rent, utilities, debt, education, etc.)
    fixed_streams = detect_fixed_expenses(user_events, request_date)
    streams.concat(fixed_streams)

    # 4. Detect variable recurring spending at category level (groceries, transport, dining)
    variable_streams = detect_variable_expenses(user_events, request_date)
    streams.concat(variable_streams)

    streams
  end

  # --- SALARY RECURRENCE ---
  def self.detect_salary(user_events, request_date, profile)
    # Check for confirmed scheduled future salary on or after request_date
    sched_sal = user_events.find do |e|
      e['category'] == 'salary' &&
        e['status'] == 'scheduled' &&
        Date.parse(e['event_date']) >= request_date
    end

    if sched_sal
      sched_date = Date.parse(sched_sal['event_date'])
      return RecurringStream.new(
        name: sched_sal['description'] || 'Next confirmed salary',
        category: 'salary',
        event_type: 'income',
        amount: Money.parse(sched_sal['amount']),
        currency: sched_sal['currency'],
        cadence: :monthly,
        day_of_month: sched_date.day,
        anchor_date: sched_date,
        last_event_id: sched_sal['event_id'],
        is_income: true
      )
    end

    # If no scheduled future salary, evaluate settled salary history
    settled_salaries = user_events.select do |e|
      e['category'] == 'salary' &&
        e['status'] == 'settled' &&
        Date.parse(e['event_date']) <= request_date
    end.sort_by { |e| [Date.parse(e['event_date']), e['event_id']] }

    return nil if settled_salaries.empty?

    last_sal = settled_salaries.last
    desc = last_sal['description'].to_s

    # Explicit salary termination signals
    return nil if desc == 'Final employer payroll'

    # Expired seasonal or temporary contracts without scheduled extension
    if desc.match?(/Seasonal contract payment|Peak-season wages|Temporary assignment pay/)
      last_date = Date.parse(last_sal['event_date'])
      return nil if (request_date - last_date).to_i > 35
    end

    # Find latest valid base salary with non-blank amount
    base_sal = settled_salaries.reverse.find do |e|
      e['amount'] && !e['amount'].to_s.strip.empty? && !e['description'].to_s.match?(/bonus|arrears/)
    end
    base_sal ||= last_sal

    return nil unless base_sal['amount'] && !base_sal['amount'].to_s.strip.empty?

    last_date = Date.parse(base_sal['event_date'])
    # Inactive salary if last settled was over 45 days ago and not scheduled
    return nil if (request_date - last_date).to_i > 45

    RecurringStream.new(
      name: base_sal['description'] || 'Monthly salary',
      category: 'salary',
      event_type: 'income',
      amount: Money.parse(base_sal['amount']),
      currency: base_sal['currency'],
      cadence: :monthly,
      day_of_month: last_date.day,
      anchor_date: last_date,
      last_event_id: base_sal['event_id'],
      is_income: true
    )
  end

  # --- SUBSCRIPTION RECURRENCE ---
  def self.detect_subscriptions(user_events, request_date)
    sub_events = user_events.select do |e|
      e['event_type'] == 'subscription' &&
        (e['status'] == 'settled' || e['status'] == 'scheduled') &&
        Date.parse(e['event_date']) <= request_date
    end

    # Subscriptions are grouped by category
    by_cat = sub_events.group_by { |e| e['category'] }
    streams = []

    by_cat.each do |cat, evs|
      sorted = evs.sort_by { |e| [Date.parse(e['event_date']), e['event_id']] }
      last_e = sorted.last
      last_date = Date.parse(last_e['event_date'])

      # Only active subscriptions (within 40 days of request_date)
      next if (request_date - last_date).to_i > 40

      streams << RecurringStream.new(
        name: last_e['description'] || cat,
        category: cat,
        event_type: 'subscription',
        amount: Money.parse(last_e['amount']),
        currency: last_e['currency'],
        cadence: :monthly,
        day_of_month: last_date.day,
        anchor_date: last_date,
        last_event_id: last_e['event_id'],
        is_income: false
      )
    end

    streams
  end

  # --- FIXED RECURRING COMMITMENTS ---
  # Categories that typically recur monthly: rent, housing, utilities, debt_repayment,
  # education, insurance, healthcare, entertainment, family_support.
  FIXED_CATEGORIES = %w[
    rent housing utilities debt_repayment education
    insurance healthcare entertainment family_support
  ].freeze

  def self.detect_fixed_expenses(user_events, request_date)
    streams = []

    FIXED_CATEGORIES.each do |cat|
      cat_events = user_events.select do |e|
        e['category'] == cat &&
          (e['status'] == 'settled' || e['status'] == 'scheduled') &&
          Date.parse(e['event_date']) <= request_date
      end

      next if cat_events.empty?

      # Check for explicit scheduled future event
      sched = user_events.find do |e|
        e['category'] == cat &&
          e['status'] == 'scheduled' &&
          Date.parse(e['event_date']) >= request_date
      end

      # Bug 2 Rule: A single observed interval (2 occurrences) is NOT enough by itself.
      # Requires at least 3 occurrences unless an explicit scheduled future event exists.
      if cat_events.size < 3 && sched.nil?
        next
      end

      sorted = cat_events.sort_by { |e| [Date.parse(e['event_date']), e['event_id']] }
      dates = sorted.map { |e| Date.parse(e['event_date']) }

      # If we have >= 2 intervals, check consistency (monthly = 27..34 days)
      if dates.size >= 3
        intervals = dates.each_cons(2).map { |d1, d2| (d2 - d1).to_i }
        median_int = intervals.sort[intervals.size / 2]
        next unless (27..34).cover?(median_int)
      end

      last_e = sorted.last
      last_date = Date.parse(last_e['event_date'])

      # Must be active within 40 days
      next if (request_date - last_date).to_i > 40 && sched.nil?

      # Conservative amount calculation
      # For fixed items (rent, loan, family support), amounts are constant.
      # For variable items (utilities), take recent settled amount or average.
      amount = if %w[rent housing debt_repayment family_support].include?(cat)
                 Money.parse(last_e['amount'])
               else
                 # Utilities / healthcare: take maximum of recent 3 to be conservative
                 recent = sorted.last(3).map { |e| Money.parse(e['amount']) }
                 recent.max
               end

      day_of_month = sched ? Date.parse(sched['event_date']).day : last_date.day

      streams << RecurringStream.new(
        name: last_e['description'] || cat,
        category: cat,
        event_type: last_e['event_type'],
        amount: amount,
        currency: last_e['currency'],
        cadence: :monthly,
        day_of_month: day_of_month,
        anchor_date: sched ? Date.parse(sched['event_date']) : last_date,
        last_event_id: last_e['event_id'],
        is_income: false
      )
    end

    streams
  end

  # --- VARIABLE EVERYDAY EXPENSES (CATEGORY LEVEL) ---
  # Categories: groceries, transport, dining.
  # Grouped at category level so transaction memos (e.g. "Fuel refill", "Taxi")
  # belong to their category cadence rather than isolated false recurrences.
  VARIABLE_CATEGORIES = %w[groceries transport dining].freeze

  def self.detect_variable_expenses(user_events, request_date)
    streams = []

    VARIABLE_CATEGORIES.each do |cat|
      cat_events = user_events.select do |e|
        e['category'] == cat &&
          e['status'] == 'settled' &&
          Date.parse(e['event_date']) <= request_date
      end

      # Need at least 3 occurrences to establish a cadence
      next if cat_events.size < 3

      sorted = cat_events.sort_by { |e| [Date.parse(e['event_date']), e['event_id']] }
      dates = sorted.map { |e| Date.parse(e['event_date']) }
      intervals = dates.each_cons(2).map { |d1, d2| (d2 - d1).to_i }

      median_int = intervals.sort[intervals.size / 2]
      # Standard cadences: weekly (~7 days), 10-day (~10 days), bi-weekly (~14 days), tri-weekly (~21 days)
      valid_cadence = [7, 10, 14, 21].find { |c| (median_int - c).abs <= 2 }
      next unless valid_cadence

      last_e = sorted.last
      last_date = Date.parse(last_e['event_date'])

      # Conservative amount: average of recent occurrences
      recent_amts = sorted.last(6).map { |e| Money.parse(e['amount']) }
      avg_amt = Money.round(recent_amts.sum / BigDecimal(recent_amts.size.to_s))

      streams << RecurringStream.new(
        name: "Regular #{cat} spending",
        category: cat,
        event_type: 'expense',
        amount: avg_amt,
        currency: last_e['currency'],
        cadence: :interval,
        interval_days: valid_cadence,
        anchor_date: last_date,
        last_event_id: last_e['event_id'],
        is_income: false
      )
    end

    streams
  end
end
