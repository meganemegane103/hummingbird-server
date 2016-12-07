class Feed
  class ActivityList
    attr_accessor :data, :feed, :page_number, :page_size, :including,
      :sfw_filter, :blocked

    %i[limit offset ranking mark_read mark_seen].each do |key|
      define_method(key) do |value|
        data[key] = value
        self
      end
    end

    def initialize(feed, data = {})
      @feed = feed
      @data = data.with_indifferent_access
      @including = []
      @sfw_filter = false
      @maps = []
      @selects = []
    end

    def page(page_number = nil, id_lt: nil)
      if page_number
        @page_number = page_number
        update_pagination!
        self
      elsif id_lt
        where_id(:lt, id_lt)
      else
        raise ArgumentError, 'Must provide an offset or id_lt'
      end
    end

    def per(page_size)
      @page_size = page_size
      update_pagination!
      self
    end

    def sfw
      @sfw_filter = true
      self
    end

    def blocking(users)
      blocked = Set.new(users)
      select do |act|
        user_id = if act.actor.respond_to?(:id)
          act.actor.id
        else
          act.actor.split(':')[1].to_i
        end
        !blocked.include?(user_id)
      end
      self
    end

    def includes(*relationships)
      including = [relationships].flatten.map(&:to_s)
      # Hardwire subject->object, convert to symbols
      including.map! { |inc| inc.sub('subject', 'object').to_sym }
      @including += including
      self
    end

    def mark(type, values = true)
      values = [values] if values.is_a? String
      data["mark_#{type}"] = values
      self
    end

    def update_pagination!
      return unless page_size && page_number
      data[:limit] = page_size
      data[:offset] = (page_number - 1) * page_size
    end

    def where_id(operator, id)
      self.data["id_#{operator}"] = id
      self
    end

    def new(data = {})
      Feed::Activity.new(feed, data)
    end

    def add(activity)
      feed.stream_feed.add_activity(activity.as_json)
    end
    alias_method :<<, :add

    def update(activity)
      Feed.client.update_activity(activity.as_json)
    end

    def destroy(activity)
      foreign_id = Feed.get_stream_id(activity.foreign_id)
      feed.stream_feed.remove_activity(foreign_id, foreign_id: true)
    end

    def results
      feed.stream_feed.get(data)['results']
    end

    # Loads in included associations, converts to Feed::Activity[Group]
    # instances and removes any unfound association data to not break JR
    def enrich(activities)
      enricher = StreamRails::Enrich.new(including)
      if feed.aggregated? || feed.notification?
        activities = enricher.enrich_aggregated_activities(activities)
        activities = activities.map { |ag| Feed::ActivityGroup.new(feed, ag) }
      else
        activities = enricher.enrich_activities(activities)
        activities = activities.map { |a| Feed::Activity.new(feed, a) }
      end
      activities.map { |act| strip_unfound(act) }
    end

    def select(&block)
      @selects << block
      self
    end

    def map(&block)
      @maps << block
      self
    end

    def apply_select(activities)
      activities.select { |act| @selects.all? { |proc| proc.call(act) } }
    end

    def apply_maps(activities)
      activities.map do |act|
        if act.respond_to?(:activities)
          act.activities = apply_maps(act.activities)
          act
        else
          @maps.reduce(act) { |act, proc| proc.call(act) }
        end
      end
    end

    def to_a
      res = enrich(results)
      res = apply_select(res)
      res = apply_maps(res)
      return res.compact
    end

    def empty?
      to_a.empty?
    end

    private

    # Strips unfound
    def strip_unfound(activity)
      # Recurse into activities if we're passed an ActivityGroup
      if activity.respond_to?(:activities)
        activity.dup.tap do |ag|
          ag.activities = activity.activities.map { |a| strip_unfound(a) }
        end
      else
        activity.dup.tap do |act|
          # For each field we've asked to have included
          including.each do |key|
            # Delete it if it's still a String
            act.delete_field(key) if act[key].is_a? String
          end
        end
      end
    end
  end
end
