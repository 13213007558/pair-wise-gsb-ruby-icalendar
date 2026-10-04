# frozen_string_literal: true

require 'json'
require 'digest'
require 'stringio'
require 'icalendar/logger'
require 'icalendar/has_properties'
require 'icalendar/has_components'
require 'icalendar/marshable'
require 'icalendar/component'
require 'icalendar/value'
require 'icalendar/event'
require 'icalendar/parser'

module Icalendar
  module Jscalendar
    class << self
      def events_to_object(events)
        Adapter.new.events_to_object(events)
      end

      def event_to_object(event)
        Adapter.new.event_to_object(event)
      end

      def object_to_events(object)
        Adapter.new.object_to_events(object)
      end

      def parse(json)
        object_to_events(JSON.parse(json))
      end

      def generate(events)
        conversion = events_to_object(events)
        Conversion.new(JSON.generate(conversion.object), conversion.losses)
      end
    end

    EVENT_TYPE = 'Event'.freeze
    VENDOR_PREFIX = 'x-icalendar-'.freeze
    LOCAL_DATE_TIME_FORMAT = '%Y-%m-%dT%H:%M:%S'.freeze
    LOCAL_DATE_FORMAT = '%Y-%m-%d'.freeze
    ICS_DATE_TIME_FORMAT = '%Y%m%dT%H%M%S'.freeze
    ICS_DATE_FORMAT = '%Y%m%d'.freeze

    EVENT_PROPERTIES = %w[
      @type uid title description start duration timeZone showWithoutTime allDay
      locations participants alerts recurrenceRules recurrenceOverrides
      excludedRecurrenceRules status freeBusyStatus privacy color keywords url
      priority sequence created updated
    ].freeze

    OVERRIDE_PROPERTIES = %w[
      @type excluded start duration timeZone showWithoutTime allDay
      title description status locations participants alerts keywords color
      freeBusyStatus priority privacy recurrenceRules recurrenceOverrides
      excludedRecurrenceRules
    ].freeze

    MAPPED_EVENT_PROPERTIES = %w[
      uid dtstart dtend duration ip_class color created description last_modified
      location organizer priority sequence status summary transp url
      recurrence_id rrule attendee categories exdate rdate alarms
      x_jscalendar_excluded_recurrence_rule
      x_jscalendar_recurrence_rule
    ].freeze

    MAPPED_ALARM_PROPERTIES = %w[
      action trigger description summary attendee duration repeat uid acknowledged
    ].freeze

    FREQUENCIES = {
      'SECONDLY' => 'secondly',
      'MINUTELY' => 'minutely',
      'HOURLY' => 'hourly',
      'DAILY' => 'daily',
      'WEEKLY' => 'weekly',
      'MONTHLY' => 'monthly',
      'YEARLY' => 'yearly'
    }.freeze

    WEEKDAYS = {
      'SU' => 'sunday',
      'MO' => 'monday',
      'TU' => 'tuesday',
      'WE' => 'wednesday',
      'TH' => 'thursday',
      'FR' => 'friday',
      'SA' => 'saturday'
    }.freeze

    WEEKDAY_ABBR = WEEKDAYS.invert.freeze
    FIRST_DAY = WEEKDAYS.each_with_object({}) { |(abbr, day), map| map[abbr] = Date::DAYNAMES.index(day.capitalize) }
    FIRST_DAY.default = 1
    FIRST_DAY.freeze

    ROLES = {
      'CHAIR' => 'owner',
      'REQ-PARTICIPANT' => 'attendee',
      'OPT-PARTICIPANT' => 'attendee',
      'NON-PARTICIPANT' => 'informational'
    }.freeze

    STATUSES = {
      'TENTATIVE' => 'tentative',
      'CONFIRMED' => 'confirmed',
      'CANCELLED' => 'cancelled'
    }.freeze

    PRIVACY = {
      'PUBLIC' => 'public',
      'PRIVATE' => 'private',
      'CONFIDENTIAL' => 'secret'
    }.freeze

    Conversion = Struct.new(:object, :losses) do
      def to_h
        object
      end

      def to_json(*args)
        JSON.generate(object, *args)
      end
    end

    class Reporter
      attr_reader :scope
      attr_reader :losses

      def initialize(scope)
        @scope = scope
        @losses = []
      end

      def retain(path, message, data)
        add(path, 'retained_extension', message, data)
      end

      def loss(path, message, data)
        add(path, 'loss', message, data)
      end

      private

      def add(path, kind, message, data)
        entry = {
          'path' => path,
          'kind' => kind,
          'message' => message
        }
        entry['data'] = data unless data.nil?
        @losses << entry
        entry
      end
    end

    class Adapter
      def initialize
        @losses = []
      end

      def events_to_object(events)
        object = {}
        grouped = events.group_by(&:uid)

        grouped.each do |uid, group|
          masters = group.select { |event| event.recurrence_id.nil? }
          next if masters.size <= 1

          reporter = Reporter.new("events/#{uid}")
          reporter.loss("events/#{uid}", 'Multiple non-recurrence events share one UID; JSCalendar event IDs must be unique', uid)
          @losses.concat(reporter.losses)
        end

        events.select { |event| event.recurrence_id.nil? }.each do |master|
          reporter = Reporter.new("events/#{master.uid}")
          exceptions = grouped[master.uid].to_a.select { |event| event.recurrence_id }
          object[stable_key(master.uid.to_s, object.keys)] = event_to_hash(master, reporter, false, exceptions)
          @losses.concat(reporter.losses)
        end

        orphan_exceptions = events.select { |event| event.recurrence_id }
          .group_by(&:uid)
          .select { |uid, _| grouped[uid].none? { |event| event.recurrence_id.nil? } }
          .values.flatten

        orphan_exceptions.each do |event|
          reporter = Reporter.new("events/#{event.uid}")
          object[stable_key(event.uid.to_s, object.keys)] = event_to_hash(event, reporter, true)
          @losses.concat(reporter.losses)
        end

        Conversion.new(object, @losses)
      end

      def event_to_object(event)
        conversion = events_to_object([event])
        @losses.concat(conversion.losses)
        conversion
      end

      def object_to_events(object)
        events = []
        object.each do |id, data|
          next unless data.is_a?(Hash)
          reporter = Reporter.new("events/#{id}")
          if data['@type'] == EVENT_TYPE
            events.concat(event_hash_to_events(id, data, reporter))
          else
            reporter.loss("events/#{id}/@type", 'Unsupported JSCalendar object type', data['@type'])
          end
          @losses.concat(reporter.losses)
        end
        Conversion.new(events, @losses)
      end

      private

      def event_to_hash(event, reporter, standalone, exceptions = nil)
        exceptions ||= []
        data = {
          '@type' => EVENT_TYPE,
          'uid' => event.uid.to_s
        }
        data['title'] = event.summary.to_s unless event.summary.nil?
        data['description'] = event.description.to_s unless event.description.nil?
        add_time_data(data, event, reporter)
        mapped_status = STATUSES[event.status.to_s.upcase]
        if mapped_status.nil? && !event.status.nil?
          retain(reporter, data, 'status', 'Unknown iCalendar STATUS has no JSCalendar equivalent', event.status.to_s)
        elsif !mapped_status.nil?
          data['status'] = mapped_status
        end
        if event.transp.to_s.upcase == 'TRANSPARENT'
          data['freeBusyStatus'] = 'free'
        end
        mapped_privacy = PRIVACY[event.ip_class.to_s.upcase]
        if mapped_privacy.nil? && !event.ip_class.nil?
          retain(reporter, data, 'privacy', 'Unknown iCalendar CLASS has no JSCalendar equivalent', event.ip_class.to_s)
        elsif !mapped_privacy.nil?
          data['privacy'] = mapped_privacy
        end
        data['color'] = event.color.to_s unless event.color.nil?
        categories = Array(event.categories).flatten.map(&:to_s)
        data['keywords'] = categories unless categories.empty?
        data['url'] = event.url.to_s unless event.url.nil?
        data['priority'] = integer_value(event.priority) unless event.priority.nil?
        data['sequence'] = integer_value(event.sequence) unless event.sequence.nil?
        data['created'] = utc_instant(event.created) unless event.created.nil?
        data['updated'] = utc_instant(event.last_modified) unless event.last_modified.nil?
        add_location(data, event, reporter)
        add_participants(data, event, reporter)
        add_alerts(data, event, reporter)
        add_recurrence(data, event, exceptions, reporter)
        add_custom_properties(data, event, reporter, MAPPED_EVENT_PROPERTIES, reporter.scope)
        if standalone && event.recurrence_id
          recurrence_id_extension = { 'value' => raw_time(event.recurrence_id) }
          recurrence_id_extension['params'] = plain_hash(event.recurrence_id.ical_params) unless event.recurrence_id.ical_params.empty?
          retain(reporter, data, 'recurrence-id', 'Standalone export preserves RECURRENCE-ID as an extension', recurrence_id_extension)
        end
        data
      end

      def add_custom_properties(target, component, reporter, mapped_names, scope)
        properties = dump_properties(component, mapped_names)
        components = dump_custom_components(component)
        extension = {}
        extension['properties'] = properties unless properties.empty?
        extension['components'] = components unless components.empty?
        return if extension.empty?

        target[VENDOR_PREFIX + 'data'] = extension
        properties.each do |entry|
          reporter.retain("#{scope}/#{entry['name']}", 'Property has no JSCalendar equivalent and is retained in vendor extension data', entry)
        end
        components.each do |entry|
          reporter.retain("#{scope}/#{entry['name']}", 'Component has no JSCalendar equivalent and is retained in vendor extension data', entry)
        end
      end

      def dump_properties(component, mapped_names)
        names = (component.class.single_properties + component.class.multiple_properties + component.custom_properties.keys) - mapped_names - component.class.components
        names.sort.each_with_object([]) do |name, list|
          values = component.property(name)
          next if values.nil?
          values = Array(values)
          next if values.empty?
          list << { 'name' => name, 'multi' => component.class.multiple_properties.include?(name), 'values' => values.map { |value| dump_property_value(value) } }
        end
      end

      def dump_property_value(value)
        if value.is_a?(Icalendar::Values::Helpers::Array)
          {
            'array' => true,
            'delimiter' => value.value_delimiter,
            'params' => plain_hash(value.ical_params),
            'values' => value.value.map { |part| dump_property_value(part) }
          }
        else
          entry = {
            'value' => primitive_or_ical(value),
            'params' => value.respond_to?(:ical_params) ? plain_hash(value.ical_params) : {}
          }
          entry['type'] = value.value_type if value.respond_to?(:value_type)
          entry
        end
      end

      def primitive_or_ical(value)
        case value
        when Icalendar::Values::Date, Icalendar::Values::DateTime
          raw_time(value)
        when Icalendar::Values::Recur, Icalendar::Values::Duration, Icalendar::Values::Period
          value.value_ical
        when Icalendar::Value
          value.value
        else
          value
        end
      end

      def dump_custom_components(component)
        component.custom_components.flat_map do |name, components|
          Array(components).map do |child|
            { 'name' => name, 'content' => child.to_ical }
          end
        end
      end

      def retain(reporter, data, name, message, value)
        key = VENDOR_PREFIX + name
        data[key] = value
        reporter.retain("#{reporter.scope}/#{key}", message, value)
      end

      def stable_key(value, existing)
        return value unless existing.include?(value)
        suffix = 2
        while existing.include?("#{value}-#{suffix}")
          suffix += 1
        end
        "#{value}-#{suffix}"
      end

      def stable_id(prefix, *parts)
        digest = Digest::SHA1.hexdigest(parts.map(&:to_s).join('\u0000'))
        "#{prefix}-#{digest[0, 16]}"
      end

      def scalar_param(value)
        Array(value).first
      end

      def plain_hash(value)
        return {} if value.nil?
        value.is_a?(Icalendar::DowncasedHash) ? value.each.to_h : value.to_h
      end

      def integer_value(value)
        value.respond_to?(:value) ? value.value.to_i : value.to_i
      end

      def time_tzid(value)
        tzid = scalar_param(value.ical_params['tzid']) if value.respond_to?(:ical_params)
        return nil if tzid.nil? || tzid.to_s == 'UTC'
        tzid.to_s
      end

      def utc_time?(value)
        value.respond_to?(:tz_utc) ? value.tz_utc : plain_hash(value.ical_params)['tzid'].to_s == 'UTC'
      end

      def local_time_string(value)
        value.value.strftime(LOCAL_DATE_TIME_FORMAT)
      end

      def local_date_string(value)
        value.value.strftime(LOCAL_DATE_FORMAT)
      end

      def utc_instant(value)
        time = value.respond_to?(:value) ? value.value : value
        "#{time.getutc.strftime(LOCAL_DATE_TIME_FORMAT)}Z"
      end

      def add_time_data(data, event, reporter)
        start = event.dtstart
        if start.is_a?(Icalendar::Values::Date)
          data['allDay'] = true
          data['start'] = local_date_string(start)
          data['showWithoutTime'] = true
        else
          data['allDay'] = false
          data['showWithoutTime'] = false
          tzid = time_tzid(start)
          data['start'] = local_time_string(start)
          if tzid
            data['timeZone'] = tzid
          elsif utc_time?(start)
            data['timeZone'] = 'Etc/UTC'
          else
            data['showWithoutTime'] = true
          end
        end
        add_duration(data, event, reporter)
      end

      def add_duration(data, event, reporter)
        if event.duration
          data['duration'] = ical_duration_to_iso(event.duration, reporter, 'duration')
        elsif event.dtend
          if event.dtstart.is_a?(Icalendar::Values::Date)
            days = (event.dtend.value - event.dtstart.value).to_i
            data['duration'] = iso_duration(days: days)
          else
            seconds = (event.dtend.value - event.dtstart.value) * 86400
            data['duration'] = seconds_to_iso(seconds)
          end
        elsif data['allDay']
          data['duration'] = 'P1D'
        else
          data['duration'] = 'PT0S'
        end
      end

      def ical_duration_to_iso(value, reporter, name)
        duration = value.respond_to?(:value) ? value.value : value
        iso = iso_duration(
          days: duration.days.to_i,
          hours: duration.hours.to_i,
          minutes: duration.minutes.to_i,
          seconds: duration.seconds.to_i,
          negative: duration.past
        )
        if duration.weeks.to_i.nonzero?
          iso = iso_duration(days: duration.days.to_i + duration.weeks.to_i * 7, hours: duration.hours.to_i, minutes: duration.minutes.to_i, seconds: duration.seconds.to_i, negative: duration.past)
        end
        if duration.weeks.to_i.nonzero? && (duration.days.to_i + duration.hours.to_i + duration.minutes.to_i + duration.seconds.to_i).nonzero?
          reporter.loss("#{reporter.scope}/#{name}", 'JSCalendar duration does not combine weeks with other units', value.value_ical)
        end
        iso
      end

      def iso_duration(days: 0, hours: 0, minutes: 0, seconds: 0, negative: false)
        total_days = days
        total_seconds = hours * 3600 + minutes * 60 + seconds
        result = negative ? '-P'.dup : 'P'.dup
        result << "#{total_days}D" if total_days.nonzero?
        if total_seconds.nonzero?
          result << 'T'
          result << "#{hours}H" if hours.nonzero?
          result << "#{minutes}M" if minutes.nonzero?
          result << "#{seconds}S" if seconds.nonzero?
        end
        result == 'P' ? 'PT0S' : result
      end

      def seconds_to_iso(seconds)
        negative = seconds.negative?
        seconds = seconds.abs.to_i
        days, seconds = seconds.divmod(86400)
        hours, seconds = seconds.divmod(3600)
        minutes, seconds = seconds.divmod(60)
        iso_duration(days: days, hours: hours, minutes: minutes, seconds: seconds, negative: negative)
      end

      def add_location(data, event, reporter)
        return if event.location.nil?
        id = stable_id('location', event.location.to_s)
        data['locations'] = { id => { 'name' => event.location.to_s } }
        unless event.location.ical_params.empty?
          retain(reporter, data, 'location-params', 'Location parameters are not represented by the core JSCalendar location', plain_hash(event.location.ical_params))
        end
      end

      def add_participants(data, event, reporter)
        participants = {}
        unless event.organizer.nil?
          participant = participant_from_address(event.organizer, 'owner', 'accepted', reporter, 'organizer')
          participant['kind'] = 'individual'
          participant['roles'] = { 'owner' => true }
          merge_participant(participants, participant, event.organizer.to_s)
        end

        Array(event.attendee).flatten.each do |attendee|
          raw_role = scalar_param(attendee.ical_params['role'])
          role = ROLES[raw_role.to_s.upcase] || 'attendee'
          participation = participation_status(attendee)
          participant = participant_from_address(attendee, role, participation, reporter, 'attendee')
          participant['roles'] = { 'attendee' => true } if participant['roles'].nil? || participant['roles'].empty?
          if raw_role && ROLES[raw_role.to_s.upcase].nil?
            participant[VENDOR_PREFIX + 'role'] = raw_role.to_s
            reporter.retain("#{reporter.scope}/participants", 'Unknown iCalendar participant role is retained', raw_role.to_s)
          end
          merge_participant(participants, participant, attendee.to_s)
        end

        data['participants'] = participants unless participants.empty?
      end

      def participant_from_address(address, role, participation, reporter, source_name)
        params = plain_hash(address.ical_params)
        id = stable_id('participant', address.to_s)
        kind = participant_kind(params['cutype'])
        participant = {
          'roles' => { role_key(role) => true },
          'participationStatus' => participation,
          'sendTo' => send_to(address, params)
        }
        participant['kind'] = kind unless kind == 'individual'
        name = scalar_param(params['cn'])
        participant['name'] = name.to_s unless name.nil?
        participant['expectReply'] = scalar_param(params['rsvp']).to_s.upcase == 'TRUE' unless params['rsvp'].nil?
        extra = participant_extra(params)
        raw_cutype = scalar_param(params['cutype'])
        if raw_cutype && !%w[INDIVIDUAL GROUP ROOM RESOURCE].include?(raw_cutype.to_s.upcase)
          extra['cutype'] = raw_cutype.to_s
        end
        raw_partstat = scalar_param(params['partstat'])
        if raw_partstat && !%w[NEEDS-ACTION ACCEPTED DECLINED TENTATIVE DELEGATED COMPLETED IN-PROCESS].include?(raw_partstat.to_s.upcase)
          extra['partstat'] = raw_partstat.to_s
        end
        unless extra.empty?
          participant[VENDOR_PREFIX + 'parameters'] = extra
          reporter.retain("#{reporter.scope}/participants/#{id}/#{VENDOR_PREFIX}parameters", 'Unmapped iCalendar participant parameters are retained', extra)
        end
        participant[VENDOR_PREFIX + 'source'] = source_name
        participant
      end

      def merge_participant(participants, participant, address)
        id = stable_id('participant', address)
        existing = participants[id]
        if existing.nil?
          participants[id] = participant
        else
          existing['roles'].merge!(participant['roles'])
          existing[VENDOR_PREFIX + 'sources'] = [existing.delete(VENDOR_PREFIX + 'source'), participant[VENDOR_PREFIX + 'source']].compact
        end
      end

      def role_key(role)
        role == 'attendee' ? 'attendee' : role
      end

      def participant_kind(value)
        case scalar_param(value).to_s.upcase
        when 'ROOM' then 'location'
        when 'RESOURCE' then 'resource'
        when 'GROUP' then 'group'
        else 'individual'
        end
      end

      def participation_status(address)
        status = scalar_param(address.ical_params['partstat']).to_s.upcase
        case status
        when 'ACCEPTED' then 'accepted'
        when 'DECLINED' then 'declined'
        when 'TENTATIVE' then 'tentative'
        when 'DELEGATED' then 'delegated'
        when 'COMPLETED' then 'completed'
        when 'IN-PROCESS' then 'in-progress'
        else
          status.empty? ? 'needs-action' : status.downcase
        end
      end

      def send_to(address, params)
        email = scalar_param(params['email'])
        if address.to_s.start_with?('mailto:') && email.nil?
          { 'imip' => address.to_s.sub(/\Amailto:/, '') }
        elsif email
          { 'imip' => email.to_s }
        else
          { 'uri' => address.to_s }
        end
      end

      def participant_extra(params)
        %w[email delegated-from delegated-to sent-by dir member language schedule-status schedule-agent schedule-force-send x-param].each_with_object({}) do |key, memo|
          memo[key] = params[key] if params.key?(key)
        end
      end

      def add_alerts(data, event, reporter)
        alerts = {}
        Array(event.alarms).flatten.each_with_index do |alarm, index|
          id = alarm.uid.nil? ? stable_id('alert', index, alarm.trigger.to_s, alarm.description.to_s) : alarm.uid.to_s
          alerts[id] = alert_to_hash(alarm, reporter, id)
        end
        data['alerts'] = alerts unless alerts.empty?
      end

      def alert_to_hash(alarm, reporter, id)
        alert = {
          '@type' => 'Alert',
          'trigger' => trigger_to_hash(alarm)
        }
        alert['acknowledged'] = utc_instant(alarm.acknowledged) unless alarm.acknowledged.nil?
        add_alert_extensions(alert, alarm, reporter, id)
        alert
      end

      def trigger_to_hash(alarm)
        trigger = alarm.trigger
        if trigger.is_a?(Icalendar::Values::DateTime)
          {
            '@type' => 'AbsoluteTrigger',
            'when' => "#{trigger.value.getutc.strftime(LOCAL_DATE_TIME_FORMAT)}Z"
          }
        else
          relative_to = scalar_param(trigger.ical_params['related']).to_s.downcase
          {
            '@type' => 'OffsetTrigger',
            'offset' => ical_duration_to_iso(trigger, Reporter.new('trigger'), 'offset'),
            'relativeTo' => relative_to == 'end' ? 'end' : 'start'
          }
        end
      end

      def add_alert_extensions(alert, alarm, reporter, id)
        raw = {}
        raw['action'] = alarm.action.to_s unless alarm.action.nil?
        raw['description'] = alarm.description.to_s unless alarm.description.nil?
        raw['summary'] = alarm.summary.to_s unless alarm.summary.nil?
        raw['duration'] = alarm.duration.value_ical unless alarm.duration.nil?
        raw['repeat'] = integer_value(alarm.repeat) unless alarm.repeat.nil?
        raw['uid'] = alarm.uid.to_s unless alarm.uid.nil?
        Array(alarm.attach).flatten.each_with_index do |attachment, index|
          raw["attach-#{index}"] = { 'value' => attachment.to_s, 'params' => plain_hash(attachment.ical_params) }
        end
        unless Array(alarm.attendee).flatten.empty?
          raw['attendees'] = Array(alarm.attendee).flatten.map do |attendee|
            { 'value' => attendee.to_s, 'params' => plain_hash(attendee.ical_params) }
          end
        end
        add_alarm_custom_properties(alert, alarm, reporter, id, raw)
        unless raw.empty?
          alert[VENDOR_PREFIX + 'alarm'] = raw
          reporter.retain("#{reporter.scope}/alerts/#{id}/#{VENDOR_PREFIX}alarm", 'Unmapped VALARM data is retained', raw)
        end
      end

      def add_alarm_custom_properties(alert, alarm, reporter, id, raw)
        mapped = MAPPED_ALARM_PROPERTIES + Icalendar::Alarm.components
        properties = dump_properties(alarm, mapped)
        components = dump_custom_components(alarm)
        raw['properties'] = properties unless properties.empty?
        raw['components'] = components unless components.empty?
        return if raw.empty?
        alert[VENDOR_PREFIX + 'alarm'] = raw
        properties.each do |entry|
          reporter.retain("#{reporter.scope}/alerts/#{id}/#{entry['name']}", 'Alarm property has no JSCalendar equivalent and is retained', entry)
        end
      end

      def add_recurrence(data, event, exceptions, reporter)
        rules = Array(event.rrule).flatten.map { |rule| recurrence_rule_to_hash(rule, event, reporter) }
        excluded_rules = excluded_rules_from_custom_properties(event, reporter)
        data['recurrenceRules'] = rules unless rules.empty?
        data['excludedRecurrenceRules'] = excluded_rules unless excluded_rules.empty?
        overrides = {}
        Array(event.exdate).flatten.each do |date|
          add_exclusion(overrides, date, event, reporter)
        end
        Array(event.rdate).flatten.each do |date|
          add_rdate(overrides, date, event, reporter)
        end
        exceptions.each do |exception|
          add_exception(overrides, event, exception, reporter)
        end
        data['recurrenceOverrides'] = overrides unless overrides.empty?
      end

      def excluded_rules_from_custom_properties(event, reporter)
        values = event.custom_property('x_jscalendar_excluded_recurrence_rule')
        values.map do |value|
          text = value.respond_to?(:value) ? value.value.to_s : value.to_s
          rule = recurrence_rule_to_hash(Icalendar::Values::Recur.new(text), event, reporter)
          rule[VENDOR_PREFIX + 'excluded'] = true
          rule
        end
      end

      def recurrence_rule_to_hash(rule, event, reporter)
        value = rule.value
        hash = { '@type' => 'RecurrenceRule' }
        frequency = FREQUENCIES[value.frequency]
        if frequency.nil?
          reporter.loss("#{reporter.scope}/recurrenceRules", 'Unsupported RRULE frequency', value.frequency)
        end
        hash['frequency'] = frequency unless frequency.nil?
        hash['interval'] = value.interval unless value.interval.nil? || value.interval == 1
        hash['count'] = value.count unless value.count.nil?
        unless value.until.nil?
          until_text = until_value(value.until, event, reporter)
          if until_text.nil?
            hash[VENDOR_PREFIX + 'rrule'] = rule.value_ical
          else
            hash['until'] = until_text
          end
        end
        hash['firstDayOfWeek'] = FIRST_DAY[value.week_start] unless value.week_start.nil?
        add_rule_parts(hash, value, reporter)
        hash
      end

      def add_rule_parts(hash, value, reporter)
        hash['bySecond'] = value.by_second unless value.by_second.nil?
        hash['byMinute'] = value.by_minute unless value.by_minute.nil?
        hash['byHour'] = value.by_hour unless value.by_hour.nil?
        hash['byDay'] = Array(value.by_day).map { |day| day_to_hash(day) } unless value.by_day.nil?
        hash['byMonthDay'] = value.by_month_day.map(&:to_i) unless value.by_month_day.nil?
        hash['byYearDay'] = value.by_year_day.map(&:to_i) unless value.by_year_day.nil?
        hash['byWeekNo'] = value.by_week_number.map(&:to_i) unless value.by_week_number.nil?
        hash['byMonth'] = value.by_month unless value.by_month.nil?
        hash['bySetPosition'] = value.by_set_position.map(&:to_i) unless value.by_set_position.nil?
      end

      def day_to_hash(day)
        match = /\A([+-]?\d{1,2})?(SU|MO|TU|WE|TH|FR|SA)\z/.match(day)
        if match
          nth = match[1].to_i
          if nth.zero?
            WEEKDAYS[match[2]]
          else
            { '@type' => 'nthDayOfWeek', 'nthPeriod' => nth, 'day' => WEEKDAYS[match[2]] }
          end
        else
          day
        end
      end

      def until_value(until_text, event, reporter)
        date = Icalendar::Values::DateTime.new(until_text.to_s) rescue Icalendar::Values::Date.new(until_text.to_s)
        if date.is_a?(Icalendar::Values::Date)
          local_date_string(date)
        elsif utc_time?(date)
          tzid = time_tzid(event.dtstart)
          converted = convert_to_zone(date.value, tzid)
          converted.nil? ? local_time_string(date) : converted.strftime(LOCAL_DATE_TIME_FORMAT)
        else
          tzid = time_tzid(event.dtstart)
          converted = convert_to_zone(date.value, tzid)
          if converted.nil?
            raw = raw_time(date)
            reporter.loss("#{reporter.scope}/recurrenceRules/until", 'Cannot convert RRULE UNTIL to the event time zone without timezone support', raw)
            nil
          else
            converted.strftime(LOCAL_DATE_TIME_FORMAT)
          end
        end
      end

      def add_exclusion(overrides, date, master, reporter)
        key = occurrence_key(date, master, reporter)
        overrides[key] = { 'excluded' => true }
        unless date.ical_params.empty?
          overrides[key][VENDOR_PREFIX + 'exdate'] = { 'value' => raw_time(date), 'params' => plain_hash(date.ical_params) }
          reporter.retain("#{reporter.scope}/recurrenceOverrides/#{key}", 'EXDATE parameters are retained', plain_hash(date.ical_params))
        end
      end

      def add_rdate(overrides, date, master, reporter)
        key = occurrence_key(date, master, reporter)
        patch = overrides[key] || {}
        if date.is_a?(Icalendar::Values::Period)
          start = date.period_start
          patch['start'] = local_time_string(start)
          patch['duration'] = date.duration ? ical_duration_to_iso(date.duration, reporter, 'recurrenceOverrides/duration') : 'PT0S'
        elsif date.is_a?(Icalendar::Values::Date)
          patch['allDay'] = true
          patch['showWithoutTime'] = true
          patch['start'] = local_date_string(date)
          patch['duration'] ||= 'P1D'
        else
          patch['allDay'] = false
          patch['showWithoutTime'] = time_tzid(date).nil? && !utc_time?(date)
          patch['start'] = local_time_string(date)
          patch['timeZone'] = time_tzid(date) || (utc_time?(date) ? 'Etc/UTC' : nil)
        end
        patch.delete('timeZone') if patch['timeZone'].nil?
        patch[VENDOR_PREFIX + 'rdate'] = { 'value' => raw_time(date), 'params' => plain_hash(date.ical_params) }
        reporter.retain("#{reporter.scope}/recurrenceOverrides/#{key}", 'RDATE is represented as a recurrence override and raw data is retained', raw_time(date))
        overrides[key] = patch
      end

      def add_exception(overrides, master, exception, reporter)
        key = recurrence_key(exception.recurrence_id, master, reporter)
        patch = {}
        %w[summary description status color ip_class transp priority].each do |name|
          master_value = master.public_send(name)
          exception_value = exception.public_send(name)
          patch[exception_field(name)] = exception_value.to_s if exception_value != master_value && !exception_value.nil?
        end
        patch['keywords'] = Array(exception.categories).flatten.map(&:to_s) if values_differ?(master.categories, exception.categories)
        add_exception_time(patch, master, exception)
        if values_differ?(master.location, exception.location) && !exception.location.nil?
          patch['locations'] = { stable_id('location', exception.location.to_s) => { 'name' => exception.location.to_s } }
        end
        add_exception_collections(patch, master, exception)
        add_custom_properties(patch, exception, reporter, MAPPED_EVENT_PROPERTIES, 'recurrenceOverrides/' + key)
        recurrence_id_extension = { 'value' => raw_time(exception.recurrence_id) }
        recurrence_id_extension['params'] = plain_hash(exception.recurrence_id.ical_params) unless exception.recurrence_id.ical_params.empty?
        patch[VENDOR_PREFIX + 'recurrence-id'] = recurrence_id_extension
        if patch.empty?
          reporter.loss("#{reporter.scope}/recurrenceOverrides/#{key}", 'Exception does not contain a representable change', nil)
        end
        overrides[key] = patch
      end

      def add_exception_time(patch, master, exception)
        return if exception.dtstart.nil? || exception.dtstart.value == master.dtstart&.value
        if exception.dtstart.is_a?(Icalendar::Values::Date)
          patch['allDay'] = true
          patch['showWithoutTime'] = true
          patch['start'] = local_date_string(exception.dtstart)
        else
          patch['allDay'] = false
          patch['showWithoutTime'] = time_tzid(exception.dtstart).nil? && !utc_time?(exception.dtstart)
          patch['start'] = local_time_string(exception.dtstart)
          tzid = time_tzid(exception.dtstart)
          patch['timeZone'] = tzid unless tzid.nil?
        end
        temporary_event = Icalendar::Event.new
        temporary_event.dtstart = exception.dtstart
        temporary_event.dtend = exception.dtend unless exception.dtend.nil?
        temporary_event.duration = exception.duration unless exception.duration.nil?
        add_duration(patch, temporary_event, Reporter.new('recurrenceOverrides/duration'))
      end

      def add_exception_collections(patch, master, exception)
        if values_differ?(master.attendee, exception.attendee)
          reporter = Reporter.new('recurrenceOverrides/participants')
          add_participants(patch, exception, reporter)
        end
        if values_differ?(master.alarms, exception.alarms)
          reporter = Reporter.new('recurrenceOverrides/alerts')
          add_alerts(patch, exception, reporter)
        end
      end

      def exception_field(name)
        { 'summary' => 'title', 'description' => 'description', 'status' => 'status', 'color' => 'color', 'ip_class' => 'privacy', 'transp' => 'freeBusyStatus', 'priority' => 'priority' }[name] || name
      end

      def values_differ?(left, right)
        Array(left).flatten.map(&:to_ical) != Array(right).flatten.map(&:to_ical)
      end

      def occurrence_key(date, master, reporter)
        actual = date.is_a?(Icalendar::Values::Period) ? date.period_start : date
        if actual.is_a?(Icalendar::Values::Date)
          local_date_string(actual)
        else
          time_occurrence_key(actual, master, reporter)
        end
      end

      def recurrence_key(date, master, reporter)
        occurrence_key(date, master, reporter)
      end

      def time_occurrence_key(date, master, reporter)
        tzid = time_tzid(master.dtstart)
        if utc_time?(date) && tzid
          converted = convert_to_zone(date.value, tzid)
          return converted.strftime(LOCAL_DATE_TIME_FORMAT) unless converted.nil?
          reporter.loss("#{reporter.scope}/recurrenceOverrides", 'Cannot convert UTC recurrence id to master time zone', raw_time(date))
        end
        local_time_string(date)
      end

      def convert_to_zone(time, tzid)
        return nil if tzid.nil?
        zone = ::Time.find_zone(tzid)
        return nil if zone.nil?

        time.respond_to?(:in_time_zone) ? time.in_time_zone(zone) : zone.local(time.year, time.month, time.day, time.hour, time.min, time.sec)
      rescue StandardError
        nil
      end

      def raw_time(value)
        actual = value.respond_to?(:value) ? value.value : value
        if actual.respond_to?(:strftime)
          actual.strftime(value.is_a?(Icalendar::Values::Date) ? ICS_DATE_FORMAT : ICS_DATE_TIME_FORMAT)
        else
          value.to_s
        end
      end

      def event_hash_to_events(id, data, reporter)
        master = build_event(id, data, reporter)
        events = [master]
        overrides = data['recurrenceOverrides'] || {}
        overrides.each do |key, patch|
          next unless patch.is_a?(Hash)
          if patch['excluded']
            append_exclusion(master, key, patch, reporter)
          elsif patch[VENDOR_PREFIX + 'rdate']
            append_rdate(master, key, patch, reporter)
          else
            events << build_exception(master, key, patch, reporter)
          end
        end
        events
      end

      def build_event(id, data, reporter, recurrence_key = nil)
        event = Icalendar::Event.new
        event.dtstamp = nil
        event.uid = data['uid'] || id
        event.summary = data['title'] if data.key?('title')
        event.description = data['description'] if data.key?('description')
        apply_start(event, data, reporter)
        event.status = data['status'].to_s.upcase if data['status']
        event.transp = 'TRANSPARENT' if data['freeBusyStatus'] == 'free'
        event.ip_class = privacy_to_ical(data['privacy']) if data['privacy']
        event.color = data['color'] if data.key?('color')
        event.categories = data['keywords'] if data.key?('keywords')
        event.url = data['url'] if data.key?('url')
        event.priority = data['priority'] if data.key?('priority')
        event.sequence = data['sequence'] if data.key?('sequence')
        event.created = instant_to_ical(data['created']) if data.key?('created')
        event.last_modified = instant_to_ical(data['updated']) if data.key?('updated')
        apply_location(event, data, reporter)
        apply_participants(event, data, reporter)
        apply_alerts(event, data, reporter)
        apply_recurrence_rules(event, data, reporter)
        apply_excluded_rules(event, data, reporter)
        apply_event_extension(event, data, reporter)
        if recurrence_key.nil? && data[VENDOR_PREFIX + 'recurrence-id']
          apply_recurrence_id(event, nil, data, reporter)
        end
        if recurrence_key
          apply_recurrence_id(event, recurrence_key, data, reporter)
        end
        event
      end

      def apply_start(event, data, reporter)
        start = data['start']
        return if start.nil?
        if all_day?(data)
          event.dtstart = Icalendar::Values::Date.new(ics_date(start.to_s))
        else
          event.dtstart = build_date_time(start, data)
        end
        duration = data['duration'] || (all_day?(data) ? 'P1D' : nil)
        return if duration.nil?
        if all_day?(data)
          days = parse_duration_days(duration, reporter)
          event.dtend = Icalendar::Values::Date.new((::Date.strptime(start.to_s) + days).strftime(ICS_DATE_FORMAT))
        else
          event.duration = duration.to_s
        end
      end

      def all_day?(data)
        data['allDay'] == true
      end

      def build_date_time(value, data)
        text = value.to_s
        if text.end_with?('Z')
          Icalendar::Values::DateTime.new(text.sub(/\Az\z/, ''), 'tzid' => 'UTC')
        elsif data['showWithoutTime'] == true || data['timeZone'].nil?
          Icalendar::Values::DateTime.new(ics_date_time(text))
        else
          Icalendar::Values::DateTime.new(ics_date_time(text), 'tzid' => data['timeZone'].to_s)
        end
      end

      def ics_date_time(value)
        parsed = ::DateTime.strptime(value.to_s, LOCAL_DATE_TIME_FORMAT)
        parsed.strftime(ICS_DATE_TIME_FORMAT)
      end

      def ics_date(value)
        value.delete('-')
      end

      def instant_to_ical(value)
        text = value.to_s
        text.end_with?('Z') ? Icalendar::Values::DateTime.new(text.sub(/\Az\z/, ''), 'tzid' => 'UTC') : Icalendar::Values::DateTime.new(ics_date_time(text))
      end

      def privacy_to_ical(value)
        { 'public' => 'PUBLIC', 'private' => 'PRIVATE', 'secret' => 'CONFIDENTIAL' }[value.to_s] || value.to_s
      end

      def parse_duration_days(duration, reporter)
        match = /\A(-?)P(?:(\d+)W)?(?:(\d+)D)?\z/.match(duration.to_s)
        if match.nil?
          reporter.loss("#{reporter.scope}/duration", 'All-day duration must be day based; using zero days', duration)
          return 0
        end
        days = match[2].to_i * 7 + match[3].to_i
        match[1] == '-' ? -days : days
      end

      def apply_location(event, data, reporter)
        locations = data['locations']
        return if locations.nil?
        location = locations.values.first
        if location.is_a?(Hash)
          event.location = location['name'].to_s if location['name']
        else
          event.location = location.to_s
        end
      end

      def apply_participants(event, data, reporter)
        participants = data['participants'] || {}
        participants.each do |id, participant|
          next unless participant.is_a?(Hash)
          source = participant[VENDOR_PREFIX + 'source']
          roles = participant['roles'] || {}
          address = participant_address(participant)
          params = participant_params(participant)
          if source == 'organizer' || roles.key?('owner')
            event.organizer = Icalendar::Values::CalAddress.new(address, params)
          else
            event.append_attendee Icalendar::Values::CalAddress.new(address, params)
          end
        end
      end

      def participant_address(participant)
        send_to = participant['sendTo'] || {}
        if send_to.key?('imip')
          "mailto:#{send_to['imip']}"
        else
          send_to['uri'].to_s
        end
      end

      def participant_params(participant)
        params = {}
        params['cn'] = participant['name'] if participant['name']
        params['partstat'] = participant['participationStatus']&.upcase if participant['participationStatus']
        params['rsvp'] = participant['expectReply'] ? 'TRUE' : 'FALSE' if participant.key?('expectReply')
        params['cutype'] = participant_kind_to_ical(participant['kind']) if participant['kind']
        extra = participant[VENDOR_PREFIX + 'parameters'] || {}
        extra = extra.merge('role' => participant[VENDOR_PREFIX + 'role']) if participant[VENDOR_PREFIX + 'role']
        params.merge(extra)
      end

      def participant_kind_to_ical(kind)
        { 'location' => 'ROOM', 'resource' => 'RESOURCE', 'group' => 'GROUP', 'individual' => 'INDIVIDUAL' }[kind] || kind.to_s.upcase
      end

      def apply_alerts(event, data, reporter)
        alerts = data['alerts'] || {}
        alerts.each do |id, alert|
          next unless alert.is_a?(Hash)
          alarm = event.alarm
          alarm.uid = id
          apply_trigger(alarm, alert, data, reporter)
          alarm.acknowledged = instant_to_ical(alert['acknowledged']) if alert['acknowledged']
          apply_alert_extension(alarm, alert, reporter, id)
        end
      end

      def apply_trigger(alarm, alert, event_data, reporter)
        trigger = alert['trigger'] || {}
        case trigger['@type']
        when 'AbsoluteTrigger'
          alarm.trigger = instant_to_ical(trigger['when'])
        else
          duration = Icalendar::Values::Duration.new(trigger['offset'].to_s)
          duration.ical_params['related'] = 'END' if trigger['relativeTo'] == 'end'
          alarm.trigger = duration
        end
      end

      def apply_alert_extension(alarm, alert, reporter, id)
        raw = alert[VENDOR_PREFIX + 'alarm']
        return if raw.nil?
        alarm.action = raw['action'] if raw['action']
        alarm.description = raw['description'] if raw['description']
        alarm.summary = raw['summary'] if raw['summary']
        alarm.duration = raw['duration'] if raw['duration']
        alarm.repeat = raw['repeat'] if raw['repeat']
        Array(raw['attendees']).each do |attendee|
          alarm.append_attendee Icalendar::Values::CalAddress.new(attendee['value'], stored_params(attendee))
        end
        restore_properties(alarm, raw['properties'] || [], reporter, "alerts/#{id}")
        restore_custom_components(alarm, raw['components'] || [], reporter, "alerts/#{id}")
      end

      def apply_recurrence_rules(event, data, reporter)
        Array(data['recurrenceRules']).each do |rule|
          raw_rule = rule[VENDOR_PREFIX + 'rrule']
          if raw_rule
            event.append_rrule(raw_rule)
          elsif FREQUENCIES.invert[rule['frequency']].nil?
            event.append_custom_property('x_jscalendar_recurrence_rule', JSON.generate(rule))
            reporter.loss("#{reporter.scope}/recurrenceRules", 'Unsupported recurrence frequency is retained as custom data', rule['frequency'])
          else
            event.append_rrule(recurrence_rule_to_ical(rule, data, reporter))
          end
        end
      end

      def recurrence_rule_to_ical(rule, source_data = {}, reporter = Reporter.new('recurrenceRules'))
        parts = []
        frequency = FREQUENCIES.invert[rule['frequency']]
        unless frequency
          reporter.loss("#{reporter.scope}/recurrenceRules", 'Unsupported JSCalendar recurrence frequency', rule['frequency'])
        end
        parts << "FREQ=#{frequency}" if frequency
        parts << "INTERVAL=#{rule['interval']}" if rule['interval']
        parts << "COUNT=#{rule['count']}" if rule['count']
        parts << "UNTIL=#{rule_until_to_ical(rule['until'], source_data)}" if rule['until']
        parts << "BYSECOND=#{Array(rule['bySecond']).join(',')}" if rule['bySecond']
        parts << "BYMINUTE=#{Array(rule['byMinute']).join(',')}" if rule['byMinute']
        parts << "BYHOUR=#{Array(rule['byHour']).join(',')}" if rule['byHour']
        parts << "BYDAY=#{Array(rule['byDay']).map { |day| day_to_ical(day) }.join(',')}" if rule['byDay']
        parts << "BYMONTHDAY=#{Array(rule['byMonthDay']).join(',')}" if rule['byMonthDay']
        parts << "BYYEARDAY=#{Array(rule['byYearDay']).join(',')}" if rule['byYearDay']
        parts << "BYWEEKNO=#{Array(rule['byWeekNo']).join(',')}" if rule['byWeekNo']
        parts << "BYMONTH=#{Array(rule['byMonth']).join(',')}" if rule['byMonth']
        parts << "BYSETPOS=#{Array(rule['bySetPosition']).join(',')}" if rule['bySetPosition']
        parts << "WKST=#{weekday_abbr(Date::DAYNAMES[rule['firstDayOfWeek'].to_i].downcase)}" if rule['firstDayOfWeek']
        Icalendar::Values::Recur.new(parts.join(';'))
      end

      def day_to_ical(day)
        return weekday_abbr(day) unless day.is_a?(Hash)
        "#{day['nthPeriod']}#{weekday_abbr(day['day'])}"
      end

      def weekday_abbr(day)
        WEEKDAY_ABBR[day]
      end

      def rule_until_to_ical(value, source_data = {})
        text = value.to_s
        return text.delete('-') if text =~ /\A\d{4}-\d{2}-\d{2}\z/
        if text.end_with?('Z')
          ics_date_time(text.sub(/\Az\z/, '')) + 'Z'
        elsif source_data['timeZone']
          utc_local_time(text, source_data['timeZone'])
        else
          ics_date_time(text)
        end
      end

      def utc_local_time(text, tzid)
        time = ::Time.find_zone(tzid).parse(text)
        time.utc.strftime(ICS_DATE_TIME_FORMAT) + 'Z'
      rescue StandardError
        ics_date_time(text)
      end

      def apply_excluded_rules(event, data, reporter)
        Array(data['excludedRecurrenceRules']).each do |rule|
          text = (rule[VENDOR_PREFIX + 'rrule'] || recurrence_rule_to_ical(rule, {}, reporter).value_ical)
          event.append_custom_property 'x_jscalendar_excluded_recurrence_rule', text
          reporter.retain("#{reporter.scope}/excludedRecurrenceRules", 'JSCalendar excludedRecurrenceRules has no direct iCalendar property and is retained', text)
        end
      end

      def append_exclusion(master, key, patch, reporter)
        raw = patch[VENDOR_PREFIX + 'exdate']
        value = raw ? raw['value'] : occurrence_to_ics(key)
        params = raw ? raw['params'] || {} : exclusion_params(master, value)
        append_date_value(master, :append_exdate, value, params)
      end

      def append_rdate(master, key, patch, reporter)
        raw = patch[VENDOR_PREFIX + 'rdate']
        value = raw['value'].to_s
        if value.include?('/')
          master.append_rdate Icalendar::Values::Period.new(value, stored_params(raw))
        else
          append_date_value(master, :append_rdate, value, raw['params'] || {})
        end
      end

      def occurrence_to_ics(key)
        text = key.to_s
        text =~ /\A\d{4}-\d{2}-\d{2}\z/ ? text.delete('-') : ics_date_time(text)
      end

      def master_start_data(master)
        { 'allDay' => master.dtstart.is_a?(Icalendar::Values::Date) }
      end

      def exclusion_params(master, value)
        return { 'value' => 'DATE' } if value.to_s =~ /\A\d{8}\z/
        params = plain_hash(master.dtstart.ical_params)
        params['tzid'] = 'UTC' if master.dtstart.respond_to?(:tz_utc) && master.dtstart.tz_utc
        params
      end

      def append_date_value(component, method, value, params)
        normalized_params = params.each_with_object({}) { |(key, param_value), memo| memo[key] = scalar_param(param_value) }
        if normalized_params['value'].to_s.upcase == 'DATE' || value.to_s =~ /\A\d{8}\z/
          normalized_params.delete('value')
          component.public_send(method, Icalendar::Values::Date.new(value, normalized_params))
        else
          component.public_send(method, Icalendar::Values::DateTime.new(value, normalized_params))
        end
      end

      def build_exception(master, key, patch, reporter)
        event = Marshal.load(Marshal.dump(master))
        event.dtstamp = nil
        event.instance_variable_set(:@rrule, [])
        event.instance_variable_set(:@rdate, [])
        event.instance_variable_set(:@exdate, [])
        if patch.key?('participants')
          event.instance_variable_set(:@attendee, [])
          event.remove_instance_variable(:@organizer) if event.instance_variable_defined?(:@organizer)
        end
        event.instance_variable_set(:@alarms, []) if patch.key?('alerts')
        apply_recurrence_id(event, key, patch, reporter)
        event.summary = patch['title'] if patch.key?('title')
        event.description = patch['description'] if patch.key?('description')
        event.status = patch['status'].to_s.upcase if patch['status']
        event.color = patch['color'] if patch.key?('color')
        event.ip_class = privacy_to_ical(patch['privacy']) if patch['privacy']
        event.transp = 'TRANSPARENT' if patch['freeBusyStatus'] == 'free'
        event.priority = patch['priority'] if patch.key?('priority')
        event.categories = patch['keywords'] if patch.key?('keywords')
        apply_start(event, patch, reporter) if patch['start']
        apply_location(event, patch, reporter) if patch['locations']
        apply_participants(event, patch, reporter) if patch['participants']
        apply_alerts(event, patch, reporter) if patch['alerts']
        apply_recurrence_rules(event, patch, reporter) if patch['recurrenceRules']
        apply_excluded_rules(event, patch, reporter) if patch['excludedRecurrenceRules']
        apply_event_extension(event, patch, reporter)
        event
      end

      def apply_recurrence_id(event, key, patch, reporter)
        raw = patch[VENDOR_PREFIX + 'recurrence-id']
        if raw
          append_date_value(event, :recurrence_id=, raw.is_a?(Hash) ? raw['value'] : raw, raw.is_a?(Hash) ? raw['params'] || {} : {})
        else
          value = occurrence_to_ics(key)
          if value =~ /\A\d{8}\z/
            event.recurrence_id = Icalendar::Values::Date.new(value)
          else
            params = event.dtstart.respond_to?(:ical_params) ? plain_hash(event.dtstart.ical_params) : {}
            event.recurrence_id = Icalendar::Values::DateTime.new(value, params)
          end
        end
      end

      def apply_event_extension(event, data, reporter)
        known = EVENT_PROPERTIES + OVERRIDE_PROPERTIES
        unknown_keys = data.keys.reject { |key| known.include?(key) || key.start_with?(VENDOR_PREFIX) }
        unknown_keys.each do |key|
          event.append_custom_property(vendor_property_name(key), JSON.generate(data[key]))
          reporter.retain("#{reporter.scope}/#{key}", 'Unknown JSCalendar property is retained as an iCalendar custom property', data[key])
        end
        extension = data[VENDOR_PREFIX + 'data']
        return if extension.nil?
        restore_properties(event, extension['properties'] || [], reporter, reporter.scope)
        restore_custom_components(event, extension['components'] || [], reporter, reporter.scope)
      end

      def vendor_property_name(key)
        key.to_s.downcase.gsub(/[^a-z0-9_]+/, '_').sub(/\Ax_/, 'x_')
      end

      def restore_properties(component, entries, reporter, scope)
        entries.each do |entry|
          name = entry['name']
          entry['values'].each do |value_entry|
            value = build_stored_value(name, value_entry)
            if component.respond_to?(:append_custom_property)
              component.append_custom_property(name, value)
            else
              component.public_send("#{name}=", value)
            end
          end
        rescue StandardError => error
          reporter.loss("#{scope}/#{entry['name']}", 'Retained property could not be restored', 'error' => error.message)
        end
      end

      def build_stored_value(name, entry)
        if entry['array']
          values = entry['values'].map { |part| build_typed_value(part['value'].to_s, part) }
          Icalendar::Values::Helpers::Array.new(values, Icalendar::Values::Text, stored_params(entry), delimiter: entry['delimiter'] || ',')
        else
          build_typed_value(entry['value'], entry)
        end
      end

      def build_typed_value(value, entry)
        params = stored_params(entry)
        case entry['type']
        when 'DATE-TIME' then Icalendar::Values::DateTime.new(value.to_s, params)
        when 'DATE' then Icalendar::Values::Date.new(value.to_s, params)
        when 'DURATION' then Icalendar::Values::Duration.new(value.to_s)
        when 'RECUR' then Icalendar::Values::Recur.new(value.to_s)
        when 'URI', 'CAL-ADDRESS' then Icalendar::Values::CalAddress.new(value.to_s, params)
        when 'INTEGER' then Icalendar::Values::Integer.new(value)
        when 'FLOAT' then Icalendar::Values::Float.new(value)
        when 'BOOLEAN' then Icalendar::Values::Boolean.new(value)
        else
          value.is_a?(::Array) ? JSON.generate(value) : value
        end
      end

      def stored_params(entry)
        (entry['params'] || {}).each_with_object({}) do |(key, value), params|
          params[key] = scalar_param(value)
        end
      end

      def restore_custom_components(component, entries, reporter, scope)
        entries.each do |entry|
          name = entry['name'].to_s
          parsed = Icalendar::Component.parse(StringIO.new(entry['content']))
          component.add_custom_component(name, parsed.first)
        rescue StandardError => error
          reporter.loss("#{scope}/#{entry['name']}", 'Retained component could not be restored', 'error' => error.message)
        end
      end
    end
  end

  JSCalendar = Jscalendar
end
