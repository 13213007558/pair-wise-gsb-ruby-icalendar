# frozen_string_literal: true

begin
  require 'tzinfo'
rescue LoadError
  # TZInfo is optional; without it, conversions between UTC and a named
  # timezone are skipped and reported instead of guessed.
end

module Icalendar
  module JSCalendar

    # Shared value conversions between RFC 5545 and RFC 8984 representations.
    module Helpers
      LOCAL_DATETIME_FORMAT = '%Y-%m-%dT%H:%M:%S'
      ICAL_DATETIME_FORMAT = '%Y%m%dT%H%M%S'
      ICAL_DATE_FORMAT = '%Y%m%d'
      SECONDS_PER_DAY = 86_400

      module_function

      def all_day?(value)
        value.is_a? Icalendar::Values::Date
      end

      # Date or DateTime to a JSCalendar LocalDateTime, e.g. "2026-10-04T09:00:00"
      def local_datetime_string(value)
        value.strftime LOCAL_DATETIME_FORMAT
      end

      def parse_local_datetime(string)
        ::DateTime.strptime string.to_s, LOCAL_DATETIME_FORMAT
      end

      # Any time-like value to a JSCalendar UTCDateTime, e.g. "2026-10-04T13:00:00Z"
      def utc_datetime_string(value)
        datetime = value.to_datetime
        datetime = datetime.new_offset 0 unless datetime.offset.zero?
        "#{datetime.strftime LOCAL_DATETIME_FORMAT}Z"
      end

      # JSCalendar UTCDateTime to an iCalendar DATE-TIME string in UTC
      def utc_string_to_ical(string)
        datetime = parse_local_datetime string.to_s.sub(/\s*[zZ]\z/, '')
        "#{datetime.strftime ICAL_DATETIME_FORMAT}Z"
      end

      # Signed ISO 8601 duration (iCalendar and JSCalendar share the syntax)
      # to a number of seconds.
      def duration_to_seconds(duration)
        fields = duration.is_a?(Icalendar::Values::Duration) ? duration.value : Icalendar::Values::Duration.new(duration).value
        seconds = (((fields.weeks * 7 + fields.days) * 24 + fields.hours) * 60 + fields.minutes) * 60 + fields.seconds
        fields.past ? -seconds : seconds
      end

      # Number of seconds to a signed ISO 8601 duration, e.g. "-PT15M"
      def seconds_to_duration(total_seconds)
        sign = total_seconds.negative? ? '-' : ''
        remaining = total_seconds.abs
        days, remaining = remaining.divmod SECONDS_PER_DAY
        hours, remaining = remaining.divmod 3600
        minutes, seconds = remaining.divmod 60
        return "#{sign}PT0S" if (days + hours + minutes + seconds).zero?

        duration = +"#{sign}P"
        duration << "#{days}D" if days.positive?
        if (hours + minutes + seconds).positive?
          duration << 'T'
          duration << "#{hours}H" if hours.positive?
          duration << "#{minutes}M" if minutes.positive?
          duration << "#{seconds}S" if seconds.positive?
        end
        duration
      end

      # Property values may be wrapped in Helpers::Array when several values
      # share one property line; always work with a flat array.
      def flatten_values(values)
        Array(values).flat_map do |value|
          value.is_a?(Icalendar::Values::Helpers::Array) ? value.to_a : [value]
        end.compact
      end

      # ical_params values are arrays when produced by the parser and plain
      # scalars when assigned by a user; read the first value either way.
      def param_first(params, key)
        value = params[key]
        value.is_a?(::Array) ? value.first : value
      end

      def params_to_h(params)
        hash = {}
        params.each { |key, value| hash[key] = value }
        hash
      end

      # Convert an iCalendar UTC DATE-TIME (e.g. "20261231T090000Z") to a
      # JSCalendar LocalDateTime in the named timezone. Returns nil when
      # TZInfo is unavailable or the zone is unknown.
      def utc_ical_to_zone_local(ical_string, tzid)
        zone = timezone tzid
        return nil if zone.nil?

        utc = ::DateTime.strptime ical_string.to_s.sub(/\s*[zZ]\z/, ''), ICAL_DATETIME_FORMAT
        zone.utc_to_local(utc).strftime LOCAL_DATETIME_FORMAT
      end

      # Convert a JSCalendar LocalDateTime in the named timezone to an
      # iCalendar UTC DATE-TIME (without the trailing Z). Returns nil when
      # TZInfo is unavailable or the zone is unknown.
      def zone_local_to_utc_ical(local_string, tzid)
        zone = timezone tzid
        return nil if zone.nil?

        zone.local_to_utc(parse_local_datetime(local_string)).strftime ICAL_DATETIME_FORMAT
      end

      def timezone(tzid)
        return nil unless defined?(::TZInfo)

        ::TZInfo::Timezone.get tzid.to_s
      rescue ::TZInfo::InvalidTimezoneIdentifier
        nil
      end
    end

  end
end
