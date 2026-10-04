# frozen_string_literal: true

module Icalendar
  module JSCalendar

    # Converts an Icalendar::Event into a JSCalendar Event (RFC 8984) Hash.
    class Exporter
      # Event properties mapped explicitly below; anything else is preserved
      # as extension data and reported.
      HANDLED_PROPERTIES = %w[
        uid summary description dtstart dtend duration status categories
        ip_class transp color created last_modified location geo
        organizer attendee rrule rdate exdate
      ].freeze

      STATUS_MAP = %w[confirmed cancelled tentative].freeze
      PRIVACY_MAP = %w[public private confidential].freeze
      TRANSP_MAP = { 'OPAQUE' => 'busy', 'TRANSPARENT' => 'free' }.freeze
      PARTSTAT_MAP = {
        'NEEDS-ACTION' => 'needs-action',
        'ACCEPTED' => 'accepted',
        'DECLINED' => 'declined',
        'TENTATIVE' => 'tentative',
        'DELEGATED' => 'delegated'
      }.freeze
      CUTYPE_MAP = {
        'INDIVIDUAL' => 'individual',
        'GROUP' => 'group',
        'RESOURCE' => 'resource',
        'LOCATION' => 'location'
      }.freeze

      def initialize(event, report)
        @event = event
        @report = report
      end

      def to_h
        js = { '@type' => 'Event' }
        js['uid'] = event.uid.to_s unless event.uid.nil?
        export_scalars js
        export_schedule js
        export_locations js
        export_participants js
        export_alerts js
        export_recurrence js
        export_unmapped_properties js
        restore_jscalendar_extensions js
        js
      end

      private

      attr_reader :event, :report

      def export_scalars(js)
        js['title'] = event.summary.to_s unless event.summary.nil?
        js['description'] = event.description.to_s unless event.description.nil?
        export_enum(js, 'status', 'status', event.status, STATUS_MAP) { |v| v.downcase }
        export_enum(js, 'privacy', 'ip_class', event.ip_class, PRIVACY_MAP) { |v| v.downcase }
        unless event.transp.nil?
          mapped = TRANSP_MAP[event.transp.to_s.upcase]
          mapped.nil? ? preserve_property(js, 'transp', event.transp) : js['freeBusyStatus'] = mapped
        end
        js['color'] = event.color.to_s unless event.color.nil?
        categories = Helpers.flatten_values(event.categories).map(&:to_s)
        js['keywords'] = categories.map { |c| [c, true] }.to_h unless categories.empty?
        js['created'] = Helpers.utc_datetime_string(event.created) unless event.created.nil?
        js['updated'] = Helpers.utc_datetime_string(event.last_modified) unless event.last_modified.nil?
      end

      def export_enum(js, key, property, value, allowed)
        return if value.nil?

        mapped = yield value.to_s
        allowed.include?(mapped) ? js[key] = mapped : preserve_property(js, property, value)
      end

      def export_schedule(js)
        dtstart = event.dtstart
        return if dtstart.nil?

        js['start'] = Helpers.local_datetime_string(dtstart)
        if Helpers.all_day?(dtstart)
          js['showWithoutTime'] = true
          days = all_day_duration_days
          js['duration'] = "P#{days}D" if days
        else
          tzid = Helpers.param_first(dtstart.ical_params, 'tzid')
          js['timeZone'] = tzid == 'UTC' ? 'Etc/UTC' : tzid.to_s unless tzid.nil?
          seconds = schedule_duration_seconds
          export_duration(js, seconds) unless seconds.nil?
        end
      end

      def export_duration(js, seconds)
        if seconds.negative?
          report.add :export, 'duration', :lost, 'JSCalendar durations cannot be negative'
        else
          js['duration'] = Helpers.seconds_to_duration(seconds)
        end
      end

      def schedule_duration_seconds
        if !event.duration.nil?
          Helpers.duration_to_seconds event.duration
        elsif !event.dtend.nil?
          ((event.dtend.to_datetime - event.dtstart.to_datetime) * Helpers::SECONDS_PER_DAY).to_i
        end
      end

      def all_day_duration_days
        seconds = schedule_duration_seconds
        return nil if seconds.nil?

        if seconds.negative? || (seconds % Helpers::SECONDS_PER_DAY).positive?
          report.add :export, 'duration', :lost, 'all-day event duration is not a whole number of days'
          nil
        else
          seconds / Helpers::SECONDS_PER_DAY
        end
      end

      def export_locations(js)
        geo = Helpers.flatten_values(event.geo).map(&:to_f)
        return if event.location.nil? && geo.empty?

        location = { '@type' => 'Location' }
        location['name'] = event.location.to_s unless event.location.nil?
        location['coordinates'] = "geo:#{geo[0]},#{geo[1]}" if geo.size >= 2
        js['locations'] = { 'location-1' => location }
      end

      def export_participants(js)
        participants = {}
        unless event.organizer.nil?
          participants[event.organizer.to_s] = participant_hash(event.organizer, owner: true)
        end
        Helpers.flatten_values(event.attendee).each do |attendee|
          participants[attendee.to_s] = participant_hash(attendee, owner: false)
        end
        js['participants'] = participants unless participants.empty?
      end

      def participant_hash(cal_address, owner:)
        params = cal_address.ical_params
        handled = %w[value]
        participant = { '@type' => 'Participant' }
        address = cal_address.to_s
        participant['sendTo'] = { 'imip' => address }
        participant['email'] = address.sub(/\Amailto:/i, '') if address.match?(/\Amailto:/i)
        if (cn = Helpers.param_first(params, 'cn'))
          participant['name'] = cn.to_s
          handled << 'cn'
        end
        participant['roles'] = participant_roles(params, owner, handled)
        export_partstat(participant, params, handled)
        export_rsvp(participant, params, handled)
        export_cutype(participant, params, handled)
        preserve_participant_params(participant, params, handled)
        participant
      end

      def participant_roles(params, owner, handled)
        role = Helpers.param_first(params, 'role').to_s.upcase
        handled << 'role' unless role.empty?
        return { 'owner' => true } if owner

        case role
        when '', 'REQ-PARTICIPANT' then { 'attendee' => true }
        when 'OPT-PARTICIPANT' then { 'attendee' => true, 'optional' => true }
        when 'CHAIR' then { 'chair' => true }
        when 'NON-PARTICIPANT' then { 'non-participant' => true }
        else
          handled.delete 'role'
          { 'attendee' => true }
        end
      end

      def export_partstat(participant, params, handled)
        partstat = Helpers.param_first(params, 'partstat')
        return if partstat.nil?

        mapped = PARTSTAT_MAP[partstat.to_s.upcase]
        if mapped.nil?
          report.add :export, 'attendee PARTSTAT', :preserved, "stored in #{EXTENSION_PREFIX}parameters"
        else
          participant['participationStatus'] = mapped
          handled << 'partstat'
        end
      end

      def export_rsvp(participant, params, handled)
        rsvp = Helpers.param_first(params, 'rsvp')
        return if rsvp.nil?

        participant['expectReply'] = rsvp.to_s.upcase == 'TRUE'
        handled << 'rsvp'
      end

      def export_cutype(participant, params, handled)
        cutype = Helpers.param_first(params, 'cutype')
        return if cutype.nil?

        mapped = CUTYPE_MAP[cutype.to_s.upcase]
        mapped.nil? ? report.add(:export, 'attendee CUTYPE', :preserved, "stored in #{EXTENSION_PREFIX}parameters") : participant['kind'] = mapped
        handled << 'cutype' unless mapped.nil?
      end

      def preserve_participant_params(participant, params, handled)
        leftovers = {}
        params.each do |key, value|
          leftovers[key] = value unless handled.include?(key)
        end
        return if leftovers.empty?

        participant["#{EXTENSION_PREFIX}parameters"] = leftovers
        leftovers.each_key do |key|
          report.add :export, "participant parameter #{key.upcase}", :preserved, "stored in #{EXTENSION_PREFIX}parameters"
        end
      end

      def export_alerts(js)
        return if event.alarms.empty?

        alerts = {}
        event.alarms.each_with_index do |alarm, index|
          alerts["alert-#{index + 1}"] = alert_hash(alarm)
        end
        js['alerts'] = alerts
      end

      def alert_hash(alarm)
        alert = { '@type' => 'Alert' }
        export_trigger(alert, alarm)
        export_alert_action(alert, alarm)
        alert['acknowledged'] = Helpers.utc_datetime_string(alarm.acknowledged) unless alarm.acknowledged.nil?
        preserve_alert_value(alert, 'description', alarm.description&.to_s)
        preserve_alert_value(alert, 'repeat', alarm.repeat&.to_i)
        preserve_alert_value(alert, 'duration', alarm.duration&.value_ical)
        attach = Helpers.flatten_values(alarm.attach).map(&:to_s)
        preserve_alert_value(alert, 'attach', attach) unless attach.empty?
        preserve_alert_value(alert, 'uid', alarm.uid&.to_s)
        alert
      end

      def export_trigger(alert, alarm)
        trigger = alarm.trigger
        case trigger
        when Icalendar::Values::Duration
          related = Helpers.param_first(trigger.ical_params, 'related').to_s.upcase
          alert['trigger'] = {
            '@type' => 'OffsetTrigger',
            'offset' => trigger.value_ical,
            'relativeTo' => related == 'END' ? 'end' : 'start'
          }
        when Icalendar::Values::DateTime
          alert['trigger'] = { '@type' => 'AbsoluteTrigger', 'when' => Helpers.utc_datetime_string(trigger) }
        when nil
          report.add :export, 'VALARM TRIGGER', :lost, 'alarm has no trigger'
        else
          report.add :export, 'VALARM TRIGGER', :lost, "unsupported trigger value #{trigger.class}"
        end
      end

      def export_alert_action(alert, alarm)
        action = alarm.action.to_s.upcase
        if %w[DISPLAY EMAIL].include?(action)
          alert['action'] = action.downcase
        else
          alert['action'] = 'display'
          alert["#{EXTENSION_PREFIX}action"] = action
          report.add :export, 'VALARM ACTION', :preserved, "stored in #{EXTENSION_PREFIX}action"
        end
      end

      def preserve_alert_value(alert, key, value)
        return if value.nil?

        alert["#{EXTENSION_PREFIX}#{key}"] = value
        report.add :export, "VALARM #{key.upcase}", :preserved, "stored in #{EXTENSION_PREFIX}#{key}"
      end

      def export_recurrence(js)
        rules = Helpers.flatten_values(event.rrule).map { |recur| recurrence_rule_hash(recur) }
        js['recurrenceRules'] = rules unless rules.empty?
        overrides = {}
        Helpers.flatten_values(event.exdate).each do |exdate|
          overrides[Helpers.local_datetime_string(exdate)] = { 'excluded' => true }
        end
        Helpers.flatten_values(event.rdate).each do |rdate|
          if rdate.is_a? Icalendar::Values::Period
            report.add :export, 'RDATE', :lost, 'period recurrence instances have no JSCalendar counterpart'
          else
            overrides[Helpers.local_datetime_string(rdate)] = {}
          end
        end
        js['recurrenceOverrides'] = overrides unless overrides.empty?
      end

      def recurrence_rule_hash(recur)
        rule = { 'frequency' => recur.frequency.to_s.downcase }
        rule['interval'] = recur.interval unless recur.interval.nil? || recur.interval == 1
        rule['count'] = recur.count unless recur.count.nil?
        rule['until'] = until_to_local(recur.until) unless recur.until.nil?
        rule['firstDayOfWeek'] = recur.week_start.downcase unless recur.week_start.nil?
        rule['byDay'] = recur.by_day.map { |day| by_day_hash(day) } unless recur.by_day.nil?
        rule['byMonth'] = recur.by_month.map(&:to_s) unless recur.by_month.nil?
        rule['byMonthDay'] = recur.by_month_day.map(&:to_i) unless recur.by_month_day.nil?
        rule['byWeekNo'] = recur.by_week_number.map(&:to_i) unless recur.by_week_number.nil?
        rule['byYearDay'] = recur.by_year_day.map(&:to_i) unless recur.by_year_day.nil?
        rule['byHour'] = recur.by_hour unless recur.by_hour.nil?
        rule['byMinute'] = recur.by_minute unless recur.by_minute.nil?
        rule['bySecond'] = recur.by_second unless recur.by_second.nil?
        rule['bySetPosition'] = recur.by_set_position.map(&:to_i) unless recur.by_set_position.nil?
        rule
      end

      BY_DAY_REGEX = /\A([+-]?\d+)?(SU|MO|TU|WE|TH|FR|SA)\z/i.freeze

      def by_day_hash(day)
        match = BY_DAY_REGEX.match(day.to_s)
        return { 'day' => day.to_s.downcase } if match.nil?

        hash = { 'day' => match[2].downcase }
        hash['nthOfPeriod'] = match[1].to_i unless match[1].nil?
        hash
      end

      def until_to_local(value)
        string = value.to_s
        tzid = event_tzid
        if string.match?(/[zZ]\z/) && !tzid.nil? && tzid != 'UTC'
          converted = Helpers.utc_ical_to_zone_local string, tzid
          return converted unless converted.nil?

          report.add :export, 'RRULE UNTIL', :lost,
                     "cannot convert UTC UNTIL to #{tzid} without tzinfo; kept UTC wall time"
        end
        string = string.sub(/\s*[zZ]\z/, '')
        format = string.length == 8 ? Helpers::ICAL_DATE_FORMAT : Helpers::ICAL_DATETIME_FORMAT
        ::DateTime.strptime(string, format).strftime Helpers::LOCAL_DATETIME_FORMAT
      end

      def event_tzid
        dtstart = event.dtstart
        return nil if dtstart.nil? || Helpers.all_day?(dtstart)

        Helpers.param_first(dtstart.ical_params, 'tzid')&.to_s
      end

      def export_unmapped_properties(js)
        preserved = []
        (event.class.properties + event.custom_properties.keys).each do |property|
          next if HANDLED_PROPERTIES.include? property
          next if property == PRESERVED_JSCALENDAR_PROPERTY.tr('-', '_')

          Helpers.flatten_values(event.property(property)).each do |value|
            preserved << {
              'name' => ical_property_name(property),
              'parameters' => Helpers.params_to_h(value.ical_params),
              'value' => value.value_ical
            }
            report.add :export, ical_property_name(property), :preserved, "stored in #{PRESERVED_PROPERTIES_KEY}"
          end
        end
        js[PRESERVED_PROPERTIES_KEY] = (js[PRESERVED_PROPERTIES_KEY] || []) + preserved unless preserved.empty?
      end

      def preserve_property(js, name, value)
        js[PRESERVED_PROPERTIES_KEY] ||= []
        js[PRESERVED_PROPERTIES_KEY] << {
          'name' => ical_property_name(name),
          'parameters' => Helpers.params_to_h(value.ical_params),
          'value' => value.value_ical
        }
        report.add :export, ical_property_name(name), :preserved, "stored in #{PRESERVED_PROPERTIES_KEY}"
      end

      def ical_property_name(property)
        property.sub(/\Aip_/, '').tr('_', '-').upcase
      end

      # JSCalendar keys preserved by a previous import are restored so an
      # import/export cycle does not lose them.
      def restore_jscalendar_extensions(js)
        stored = event.custom_properties[PRESERVED_JSCALENDAR_PROPERTY.tr('-', '_')]
        return if stored.nil? || stored.empty?

        data = JSON.parse stored.first.to_s
        data.each { |key, value| js[key] = value unless js.key? key }
      rescue JSON::ParserError
        report.add :export, PRESERVED_JSCALENDAR_PROPERTY, :lost, 'preserved JSCalendar data is not valid JSON'
      end
    end

  end
end
