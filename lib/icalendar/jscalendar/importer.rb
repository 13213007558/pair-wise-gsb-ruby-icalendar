# frozen_string_literal: true

module Icalendar
  module JSCalendar

    # Converts a JSCalendar Event (RFC 8984) Hash into an Icalendar::Event.
    class Importer
      HANDLED_KEYS = [
        '@type', 'uid', 'title', 'description', 'start', 'timeZone', 'duration',
        'showWithoutTime', 'status', 'keywords', 'privacy', 'freeBusyStatus',
        'color', 'created', 'updated', 'locations', 'participants', 'alerts',
        'recurrenceRules', 'recurrenceOverrides', PRESERVED_PROPERTIES_KEY
      ].freeze

      FREEBUSY_MAP = { 'busy' => 'OPAQUE', 'free' => 'TRANSPARENT' }.freeze
      KIND_MAP = {
        'individual' => 'INDIVIDUAL',
        'group' => 'GROUP',
        'resource' => 'RESOURCE',
        'location' => 'LOCATION'
      }.freeze
      PARTICIPANT_KEYS = [
        '@type', 'name', 'email', 'sendTo', 'roles', 'participationStatus',
        'expectReply', 'kind', "#{EXTENSION_PREFIX}parameters"
      ].freeze
      ALERT_KEYS = [
        '@type', 'trigger', 'action', 'acknowledged',
        "#{EXTENSION_PREFIX}action", "#{EXTENSION_PREFIX}description",
        "#{EXTENSION_PREFIX}repeat", "#{EXTENSION_PREFIX}duration",
        "#{EXTENSION_PREFIX}attach", "#{EXTENSION_PREFIX}uid"
      ].freeze
      RULE_KEYS = %w[
        frequency interval count until firstDayOfWeek byDay byMonth byMonthDay
        byWeekNo byYearDay byHour byMinute bySecond bySetPosition
      ].freeze

      def initialize(jscalendar, report)
        @js = jscalendar
        @report = report
        @preserved_overrides = {}
      end

      def to_event
        @event = Icalendar::Event.new
        report.add :import, '@type', :lost, "expected Event, got #{js['@type']}" if js.key?('@type') && js['@type'] != 'Event'
        import_scalars
        import_schedule
        import_locations
        import_participants
        import_alerts
        import_recurrence
        import_preserved_properties
        import_unmapped_keys
        event
      end

      private

      attr_reader :js, :report, :event

      def import_scalars
        event.uid = js['uid'].to_s unless js['uid'].nil?
        event.summary = js['title'] if js.key? 'title'
        event.description = js['description'] if js.key? 'description'
        event.status = js['status'].to_s.upcase unless js['status'].nil?
        event.ip_class = js['privacy'].to_s.upcase unless js['privacy'].nil?
        unless js['freeBusyStatus'].nil?
          transp = FREEBUSY_MAP[js['freeBusyStatus'].to_s]
          transp.nil? ? report.add(:import, 'freeBusyStatus', :lost, "no iCalendar TRANSP for #{js['freeBusyStatus']}") : event.transp = transp
        end
        event.color = js['color'] unless js['color'].nil?
        event.categories = js['keywords'].keys.map(&:to_s) if js['keywords'].is_a?(Hash)
        event.created = utc_value(js['created']) unless js['created'].nil?
        event.last_modified = utc_value(js['updated']) unless js['updated'].nil?
      end

      def utc_value(string)
        Icalendar::Values::DateTime.new Helpers.utc_string_to_ical(string)
      end

      def import_schedule
        if js['start'].nil?
          report.add :import, 'start', :lost, 'JSCalendar event has no start'
          return
        end

        start = Helpers.parse_local_datetime js['start']
        seconds = duration_seconds
        if js['showWithoutTime']
          date = start.to_date
          event.dtstart = Icalendar::Values::Date.new date
          import_all_day_duration(date, seconds) unless seconds.nil?
        else
          params = timezone_params
          event.dtstart = Icalendar::Values::DateTime.new start, params
          unless seconds.nil?
            event.dtend = Icalendar::Values::DateTime.new start + Rational(seconds, Helpers::SECONDS_PER_DAY), params
          end
        end
      end

      def import_all_day_duration(date, seconds)
        if seconds.negative? || (seconds % Helpers::SECONDS_PER_DAY).positive?
          report.add :import, 'duration', :lost, 'all-day event duration is not a whole number of days'
        else
          event.dtend = Icalendar::Values::Date.new date + (seconds / Helpers::SECONDS_PER_DAY)
        end
      end

      def duration_seconds
        return nil if js['duration'].nil?

        seconds = Helpers.duration_to_seconds js['duration'].to_s
        if seconds.negative?
          report.add :import, 'duration', :lost, 'JSCalendar durations cannot be negative'
          nil
        else
          seconds
        end
      end

      def timezone_params
        case js['timeZone']
        when nil then {}
        when 'Etc/UTC' then { 'tzid' => 'UTC' }
        else { 'tzid' => js['timeZone'].to_s }
        end
      end

      def import_locations
        locations = js['locations']
        return unless locations.is_a?(Hash)

        locations.each_with_index do |(id, location), index|
          if index.zero?
            import_location location
          else
            report.add :import, "locations/#{id}", :lost, 'iCalendar events carry a single LOCATION'
          end
        end
      end

      def import_location(location)
        event.location = location['name'] unless location['name'].nil?
        coordinates = location['coordinates'].to_s
        if coordinates =~ /\Ageo:(-?[\d.]+),(-?[\d.]+)/
          event.geo = [::Regexp.last_match(1).to_f, ::Regexp.last_match(2).to_f]
        elsif !coordinates.empty?
          report.add :import, 'location coordinates', :lost, "cannot parse #{coordinates}"
        end
        (location.keys - %w[@type name coordinates]).each do |key|
          report.add :import, "location #{key}", :lost, 'no iCalendar LOCATION counterpart'
        end
      end

      def import_participants
        participants = js['participants']
        return unless participants.is_a?(Hash)

        organizer_assigned = false
        participants.each do |id, participant|
          roles = participant['roles'] || {}
          if roles['owner'] && !organizer_assigned
            event.organizer = cal_address(participant, id, {})
            organizer_assigned = true
          else
            report.add :import, "participants/#{id} role owner", :lost, 'iCalendar events carry a single ORGANIZER' if roles['owner']
            event.append_attendee cal_address(participant, id, attendee_params(participant, roles))
          end
          report_unknown_keys participant, PARTICIPANT_KEYS, "participants/#{id}"
        end
      end

      def cal_address(participant, id, params)
        params['cn'] = participant['name'] unless participant['name'].nil?
        (participant["#{EXTENSION_PREFIX}parameters"] || {}).each { |key, value| params[key] = value }
        Icalendar::Values::CalAddress.new participant_address(participant, id), params
      end

      def participant_address(participant, id)
        send_to = participant['sendTo']
        return send_to['imip'].to_s if send_to.is_a?(Hash) && send_to['imip']
        return "mailto:#{participant['email']}" unless participant['email'].nil?

        id.to_s
      end

      def attendee_params(participant, roles)
        params = {}
        role = attendee_role(roles)
        params['role'] = role unless role.nil?
        params['partstat'] = participant['participationStatus'].to_s.upcase unless participant['participationStatus'].nil?
        params['rsvp'] = participant['expectReply'] ? 'TRUE' : 'FALSE' if participant.key? 'expectReply'
        unless participant['kind'].nil?
          cutype = KIND_MAP[participant['kind'].to_s]
          cutype.nil? ? report.add(:import, 'participant kind', :lost, "no iCalendar CUTYPE for #{participant['kind']}") : params['cutype'] = cutype
        end
        params
      end

      def attendee_role(roles)
        return 'CHAIR' if roles['chair']
        return 'OPT-PARTICIPANT' if roles['optional']
        return 'NON-PARTICIPANT' if roles['non-participant']

        nil
      end

      def import_alerts
        alerts = js['alerts']
        return unless alerts.is_a?(Hash)

        alerts.each do |id, alert|
          import_alert id, alert
        end
      end

      def import_alert(id, alert)
        alarm = event.alarm
        import_trigger alarm, alert['trigger']
        action = alert["#{EXTENSION_PREFIX}action"] || alert['action'] || 'display'
        alarm.action = action.to_s.upcase
        alarm.description = alert["#{EXTENSION_PREFIX}description"] || js['title'] || 'Reminder'
        alarm.acknowledged = utc_value(alert['acknowledged']) unless alert['acknowledged'].nil?
        alarm.repeat = alert["#{EXTENSION_PREFIX}repeat"] unless alert["#{EXTENSION_PREFIX}repeat"].nil?
        unless alert["#{EXTENSION_PREFIX}duration"].nil?
          alarm.duration = Icalendar::Values::Duration.new alert["#{EXTENSION_PREFIX}duration"].to_s
        end
        Array(alert["#{EXTENSION_PREFIX}attach"]).each { |attach| alarm.append_attach attach }
        alarm.uid = alert["#{EXTENSION_PREFIX}uid"] unless alert["#{EXTENSION_PREFIX}uid"].nil?
        report_unknown_keys alert, ALERT_KEYS, "alerts/#{id}"
      end

      def import_trigger(alarm, trigger)
        trigger ||= {}
        if trigger['offset']
          duration = Icalendar::Values::Duration.new trigger['offset'].to_s
          duration.ical_params['related'] = 'END' if trigger['relativeTo'] == 'end'
          alarm.trigger = duration
        elsif trigger['when']
          alarm.trigger = utc_value trigger['when']
        else
          report.add :import, 'alert trigger', :lost, 'alert has neither offset nor absolute trigger'
        end
      end

      def import_recurrence
        Array(js['recurrenceRules']).each do |rule|
          rrule = recur_string rule
          event.append_rrule rrule unless rrule.nil?
        end
        return unless js['recurrenceOverrides'].is_a?(Hash)

        js['recurrenceOverrides'].each do |key, override|
          import_override key, override || {}
        end
      end

      def recur_string(rule)
        if rule['frequency'].nil?
          report.add :import, 'recurrenceRules frequency', :lost, 'rule has no frequency'
          return nil
        end

        parts = ["FREQ=#{rule['frequency'].to_s.upcase}"]
        parts << "INTERVAL=#{rule['interval']}" unless rule['interval'].nil? || rule['interval'] == 1
        parts << "COUNT=#{rule['count']}" unless rule['count'].nil?
        parts << "UNTIL=#{until_ical(rule['until'])}" unless rule['until'].nil?
        parts << "WKST=#{rule['firstDayOfWeek'].to_s.upcase}" unless rule['firstDayOfWeek'].nil?
        append_by_parts parts, rule
        (rule.keys - RULE_KEYS).each do |key|
          report.add :import, "recurrenceRules #{key}", :lost, 'no iCalendar RRULE counterpart'
        end
        parts.join ';'
      end

      def append_by_parts(parts, rule)
        parts << by_day_string(rule['byDay']) unless rule['byDay'].nil?
        parts << by_month_string(rule['byMonth']) unless rule['byMonth'].nil?
        { 'byMonthDay' => 'BYMONTHDAY', 'byWeekNo' => 'BYWEEKNO', 'byYearDay' => 'BYYEARDAY',
          'byHour' => 'BYHOUR', 'byMinute' => 'BYMINUTE', 'bySecond' => 'BYSECOND',
          'bySetPosition' => 'BYSETPOS' }.each do |key, ical|
          parts << "#{ical}=#{Array(rule[key]).join ','}" unless rule[key].nil?
        end
      end

      def by_day_string(by_day)
        days = Array(by_day).map do |entry|
          "#{entry['nthOfPeriod']}#{entry['day'].to_s.upcase}"
        end
        "BYDAY=#{days.join ','}"
      end

      def by_month_string(by_month)
        months = Array(by_month).map do |month|
          string = month.to_s
          if string.end_with? 'L'
            report.add :import, 'recurrenceRules byMonth', :lost, "leap month #{string} has no iCalendar counterpart"
            string.chop
          else
            string
          end
        end
        "BYMONTH=#{months.join ','}"
      end

      def until_ical(value)
        datetime = Helpers.parse_local_datetime value
        if js['showWithoutTime']
          datetime.strftime Helpers::ICAL_DATE_FORMAT
        elsif js['timeZone'] == 'Etc/UTC'
          "#{datetime.strftime Helpers::ICAL_DATETIME_FORMAT}Z"
        elsif js['timeZone']
          converted = Helpers.zone_local_to_utc_ical value, js['timeZone']
          if converted.nil?
            report.add :import, 'recurrenceRules until', :lost,
                       "cannot convert local until to UTC without tzinfo; kept local wall time"
            datetime.strftime Helpers::ICAL_DATETIME_FORMAT
          else
            "#{converted}Z"
          end
        else
          datetime.strftime Helpers::ICAL_DATETIME_FORMAT
        end
      end

      def import_override(key, override)
        if override == { 'excluded' => true }
          event.append_exdate override_value(key)
        elsif override.empty?
          event.append_rdate override_value(key)
        else
          @preserved_overrides[key] = override
          report.add :import, "recurrenceOverrides/#{key}", :preserved, "stored in #{PRESERVED_JSCALENDAR_PROPERTY}"
        end
      end

      def override_value(key)
        datetime = Helpers.parse_local_datetime key
        if js['showWithoutTime']
          Icalendar::Values::Date.new datetime.to_date
        else
          Icalendar::Values::DateTime.new datetime, timezone_params
        end
      end

      def import_preserved_properties
        Array(js[PRESERVED_PROPERTIES_KEY]).each do |entry|
          name = entry['name'].to_s.downcase.tr '-', '_'
          name = "ip_#{name}" if %w[class method name].include? name
          klass = event.class.default_property_types[name]
          value = klass.new entry['value'].to_s, entry['parameters'] || {}
          event.append_custom_property name, value
        end
      end

      def import_unmapped_keys
        unmapped = {}
        js.each do |key, value|
          unmapped[key] = value unless HANDLED_KEYS.include? key
        end
        unmapped['recurrenceOverrides'] = @preserved_overrides unless @preserved_overrides.empty?
        return if unmapped.empty?

        unmapped.each_key do |key|
          report.add :import, key, :preserved, "stored in #{PRESERVED_JSCALENDAR_PROPERTY}"
        end
        event.append_custom_property PRESERVED_JSCALENDAR_PROPERTY.tr('-', '_'), JSON.generate(unmapped)
      end

      def report_unknown_keys(hash, known, context)
        (hash.keys - known).each do |key|
          report.add :import, "#{context} #{key}", :lost, 'no iCalendar counterpart'
        end
      end
    end

  end
end
