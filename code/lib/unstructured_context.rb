require_relative 'dataset'

# Determines, for every request in dataset/requests.csv, whether it has
# relevant rows in messages.csv and/or images.csv -- and which ones.
#
# Relationship rules (verified against the actual dataset, not assumed):
#
#   1. If a message/image row has request_id populated, it belongs to that
#      request directly.
#   2. Else if related_event_id is populated, resolve the event's owning
#      user_id via financial_events.csv, then map that user to their single
#      request (every user in requests.csv has exactly one request -- this
#      is a 1:1 relationship in this dataset, not a coincidence to special
#      case around).
#   3. Else fall back to the row's own user_id -> request mapping.
#   4. If no step resolves to a request that actually exists in
#      requests.csv (e.g. the row belongs to a sample_requests.csv-only
#      user, or an orphaned financial_events user with no request at all),
#      the row is dropped -- it cannot affect anything we have to predict.
#
# Every resolution step is cross-checked against the row's own user_id where
# both are available (e.g. related_event_id's owning user should equal the
# message's user_id). Mismatches are collected as warnings rather than
# silently trusted or silently dropped, since a mismatch means the dataset
# disagrees with itself and a human should look at it.
module UnstructuredContext
  RequestContext = Struct.new(:request_id, :user_id, :message_ids, :image_ids, keyword_init: true) do
    def has_unstructured_context
      !(message_ids.empty? && image_ids.empty?)
    end
  end

  Result = Struct.new(:contexts, :warnings, keyword_init: true)

  # contexts: { request_id => RequestContext }, one entry per row of requests.csv
  def self.build
    requests = Dataset.load(:requests)
    events = Dataset.load(:financial_events)
    messages = Dataset.load(:messages)
    images = Dataset.load(:images)

    request_by_user = {}
    requests.each do |r|
      request_by_user[r['user_id']] ||= []
      request_by_user[r['user_id']] << r['request_id']
    end
    # Every user has at most one request. If that stops being true for the
    # hidden set, fail loudly instead of silently guessing which request a
    # user_id-only message belongs to.
    multi = request_by_user.select { |_, ids| ids.size > 1 }
    raise "user_id maps to multiple requests, 1:1 assumption broken: #{multi}" unless multi.empty?

    request_by_user.transform_values!(&:first)

    user_by_event = {}
    events.each { |e| user_by_event[e['event_id']] = e['user_id'] }

    contexts = {}
    requests.each do |r|
      contexts[r['request_id']] = RequestContext.new(
        request_id: r['request_id'], user_id: r['user_id'], message_ids: [], image_ids: []
      )
    end

    warnings = []

    resolve = lambda do |row, id_field, id_field_label|
      row_user = row['user_id']

      if row['request_id']
        target_user = request_by_user.key(row['request_id']) # reverse lookup, fine at this scale
        if target_user && target_user != row_user
          warnings << "#{id_field_label} #{row[id_field]}: request_id #{row['request_id']} " \
                      "belongs to #{target_user}, not row's user_id #{row_user} -- trusting request_id"
        end
        next row['request_id']
      end

      if row['related_event_id']
        event_user = user_by_event[row['related_event_id']]
        if event_user.nil?
          warnings << "#{id_field_label} #{row[id_field]}: related_event_id " \
                      "#{row['related_event_id']} not found in financial_events.csv"
          next request_by_user[row_user]
        end
        if event_user != row_user
          warnings << "#{id_field_label} #{row[id_field]}: related_event_id " \
                      "#{row['related_event_id']} belongs to #{event_user}, not row's user_id " \
                      "#{row_user} -- trusting the event's owner"
        end
        next request_by_user[event_user]
      end

      request_by_user[row_user]
    end

    messages.each do |m|
      request_id = resolve.call(m, 'message_id', 'message')
      contexts[request_id]&.message_ids&.push(m['message_id'])
      # request_id resolving to nil, or to a request not in requests.csv
      # (sample-only / orphaned user), means this message can't affect any
      # prediction we have to make -- dropped intentionally, not a bug.
    end

    images.each do |img|
      request_id = resolve.call(img, 'image_id', 'image')
      contexts[request_id]&.image_ids&.push(img['image_id'])
    end

    Result.new(contexts: contexts, warnings: warnings)
  end
end
