# frozen_string_literal: true

module Icalendar

  # Jcal converts between Icalendar::Value objects and their jCal
  # (RFC 7265) JSON representations, in both directions.
  module Jcal

    KNOWN_VALUE_TYPES = %w[
      binary boolean cal-address date date-time duration float integer
      period recur text time uri utc-offset unknown
    ].freeze

    # Properties whose comma-looking value lists are actually structured
    # values, joined with ";" in iCalendar.
    STRUCTURED_VALUE_PROPERTIES = %w[geo request-status].freeze

    JCAL_DATE_REGEX = /\A\d{4}-\d{2}-\d{2}\z/.freeze
    JCAL_TIME_REGEX = /\A\d{2}:\d{2}:\d{2}Z?\z/.freeze
    JCAL_DATE_TIME_REGEX = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z?\z/.freeze
    JCAL_UTC_OFFSET_REGEX = /\A[+-]\d{2}:\d{2}(?::\d{2})?\z/.freeze
    JCAL_DURATION_REGEX = /\A[+-]?P/i.freeze

    RECUR_KEYS = {
      'freq' => 'FREQ', 'until' => 'UNTIL', 'count' => 'COUNT',
      'interval' => 'INTERVAL', 'bysecond' => 'BYSECOND',
      'byminute' => 'BYMINUTE', 'byhour' => 'BYHOUR', 'byday' => 'BYDAY',
      'bymonthday' => 'BYMONTHDAY', 'byyearday' => 'BYYEARDAY',
      'byweekno' => 'BYWEEKNO', 'bymonth' => 'BYMONTH',
      'bysetpos' => 'BYSETPOS', 'wkst' => 'WKST'
    }.freeze

    module_function

    ### object -> jCal ###

    def property_to_jcal(name, value)
      [name, params_to_jcal(value), value.value_type.downcase, *values_to_jcal(value)]
    end

    def params_to_jcal(value)
      sources = value.is_a?(Icalendar::Values::Helpers::Array) ? value.value.dup : [value]
      sources << value if value.is_a?(Icalendar::Values::Helpers::Array)
      params = {}
      sources.each do |source|
        source.ical_params.each do |key, param_value|
          next if key == 'value'
          next if key == 'tzid' && source.respond_to?(:tz_utc) && source.tz_utc
          params[key.gsub('_', '-')] = param_to_jcal param_value
        end
      end
      params
    end

    def param_to_jcal(param_value)
      if param_value.is_a? ::Array
        param_value.size == 1 ? param_value.first : param_value.dup
      else
        param_value
      end
    end

    def values_to_jcal(value)
      case value
      when Icalendar::Values::Helpers::Array
        value.value.flat_map { |element| values_to_jcal element }
      when Icalendar::Values::Unknown
        raw = value.value
        raw.is_a?(::Array) ? raw.dup : [raw]
      else
        [value_to_jcal(value)]
      end
    end

    def value_to_jcal(value)
      case value
      when Icalendar::Values::Recur
        recur_to_jcal value
      when Icalendar::Values::Period
        [date_time_to_jcal(value.period_start), period_end_to_jcal(value)]
      when Icalendar::Values::DateTime
        date_time_to_jcal value
      when Icalendar::Values::Date
        value.strftime '%Y-%m-%d'
      when Icalendar::Values::Time
        "#{value.strftime '%H:%M:%S'}#{'Z' if value.tz_utc}"
      when Icalendar::Values::UtcOffset
        value.to_s
      when Icalendar::Values::Duration
        value.value_ical
      when Icalendar::Values::Boolean, Icalendar::Values::Integer, Icalendar::Values::Float
        value.value
      else
        value.value.to_s
      end
    end

    def date_time_to_jcal(value)
      "#{value.strftime '%Y-%m-%dT%H:%M:%S'}#{'Z' if value.tz_utc}"
    end

    def period_end_to_jcal(period)
      if period.duration
        period.duration.value_ical
      else
        date_time_to_jcal period.explicit_end
      end
    end

    def recur_to_jcal(recur)
      result = {}
      result['freq'] = recur.frequency unless recur.frequency.nil?
      result['until'] = temporal_string_to_jcal(recur.until) unless recur.until.nil?
      result['count'] = recur.count unless recur.count.nil?
      result['interval'] = recur.interval unless recur.interval.nil?
      result['bysecond'] = recur.by_second unless recur.by_second.nil?
      result['byminute'] = recur.by_minute unless recur.by_minute.nil?
      result['byhour'] = recur.by_hour unless recur.by_hour.nil?
      result['byday'] = recur.by_day unless recur.by_day.nil?
      result['bymonthday'] = recur.by_month_day unless recur.by_month_day.nil?
      result['byyearday'] = recur.by_year_day unless recur.by_year_day.nil?
      result['byweekno'] = recur.by_week_number unless recur.by_week_number.nil?
      result['bymonth'] = recur.by_month unless recur.by_month.nil?
      result['bysetpos'] = recur.by_set_position unless recur.by_set_position.nil?
      result['wkst'] = recur.week_start unless recur.week_start.nil?
      result
    end

    # "19970714" / "19970714T200000Z" -> "1997-07-14" / "1997-07-14T20:00:00Z"
    def temporal_string_to_jcal(value)
      value = value.to_s
      if value.include? 'T'
        date, time = value.split 'T', 2
        zulu = time.end_with?('Z') ? 'Z' : ''
        time = time.chomp 'Z'
        "#{date[0, 4]}-#{date[4, 2]}-#{date[6, 2]}T#{time[0, 2]}:#{time[2, 2]}:#{time[4, 2]}#{zulu}"
      else
        "#{value[0, 4]}-#{value[4, 2]}-#{value[6, 2]}"
      end
    end

    ### jCal -> iCalendar strings ###

    # Converts the jCal values of a property into the iCalendar content line
    # value string, so the regular Parser value wrapping can take over.
    def values_to_ical_string(type, values, prop_name)
      delimiter = STRUCTURED_VALUE_PROPERTIES.include?(prop_name) ? ';' : ','
      raise ArgumentError, "#{type.inspect} value expects a single JSON object, got #{values.size} values" if type == 'recur' && values.size > 1
      values.map { |value| value_to_ical_string type, value }.join delimiter
    end

    def value_to_ical_string(type, value)
      case type
      when 'text'
        escape_text string_value(type, value)
      when 'date'
        validate_format string_value(type, value), JCAL_DATE_REGEX, type
        value.delete '-'
      when 'time'
        validate_format string_value(type, value), JCAL_TIME_REGEX, type
        value.delete ':'
      when 'date-time'
        validate_format string_value(type, value), JCAL_DATE_TIME_REGEX, type
        value.gsub(/[-:]/, '')
      when 'utc-offset'
        validate_format string_value(type, value), JCAL_UTC_OFFSET_REGEX, type
        value.delete ':'
      when 'duration'
        string_value type, value
      when 'period'
        period_to_ical_string value
      when 'recur'
        recur_to_ical_string value
      when 'boolean'
        unless value == true || value == false
          raise ArgumentError, "boolean value must be true or false, got #{value.inspect}"
        end
        value ? 'TRUE' : 'FALSE'
      when 'integer'
        raise ArgumentError, "integer value must be a JSON number, got #{value.inspect}" unless value.is_a? ::Integer
        value.to_s
      when 'float'
        raise ArgumentError, "float value must be a JSON number, got #{value.inspect}" unless value.is_a? ::Numeric
        value.to_s
      when 'binary', 'uri', 'cal-address'
        string_value type, value
      else
        raise ArgumentError, "unsupported jCal value type #{type.inspect}"
      end
    end

    def string_value(type, value)
      unless value.is_a? String
        raise ArgumentError, "#{type} value must be a JSON string, got #{value.inspect}"
      end
      value
    end

    def validate_format(value, regex, type)
      unless value =~ regex
        raise ArgumentError, "#{type} value #{value.inspect} does not match the jCal #{type.upcase} format"
      end
      value
    end

    ESCAPE_TEXT_BACKSLASH_REGEX = /\\/.freeze
    ESCAPE_TEXT_SPECIAL_REGEX = /([;,])/.freeze
    ESCAPE_TEXT_NEWLINE_REGEX = /\r?\n/.freeze

    def escape_text(value)
      value.gsub(ESCAPE_TEXT_BACKSLASH_REGEX, '\\\\')
           .gsub(ESCAPE_TEXT_SPECIAL_REGEX) { |char| "\\#{char}" }
           .gsub(ESCAPE_TEXT_NEWLINE_REGEX, '\\n')
    end

    def period_to_ical_string(value)
      unless value.is_a?(::Array) && value.size == 2
        raise ArgumentError, "period value must be a [start, end-or-duration] pair, got #{value.inspect}"
      end
      period_start = value_to_ical_string 'date-time', value[0]
      period_end = if value[1].is_a?(String) && value[1] =~ JCAL_DURATION_REGEX
        value[1]
      else
        value_to_ical_string 'date-time', value[1]
      end
      "#{period_start}/#{period_end}"
    end

    def recur_to_ical_string(value)
      unless value.is_a? Hash
        raise ArgumentError, "recur value must be a JSON object, got #{value.inspect}"
      end
      value.map do |key, part|
        ical_key = RECUR_KEYS[key.to_s.downcase]
        raise ArgumentError, "unknown recur part #{key.inspect}" if ical_key.nil?
        "#{ical_key}=#{recur_part_to_ical_string key.to_s.downcase, part}"
      end.join ';'
    end

    def recur_part_to_ical_string(key, part)
      case key
      when 'freq', 'wkst'
        string_value('recur', part).upcase
      when 'until'
        temporal_string_to_ical part
      when 'count', 'interval'
        raise ArgumentError, "recur #{key} must be a number, got #{part.inspect}" unless part.is_a? ::Integer
        part.to_s
      else
        list = part.is_a?(::Array) ? part : [part]
        list.map { |element| recur_list_element key, element }.join ','
      end
    end

    def recur_list_element(key, element)
      if key == 'byday'
        string_value 'recur', element
      else
        unless element.is_a? ::Integer
          raise ArgumentError, "recur #{key} entries must be numbers, got #{element.inspect}"
        end
        element.to_s
      end
    end

    # "1997-07-14" / "1997-07-14T20:00:00Z" -> "19970714" / "19970714T200000Z"
    def temporal_string_to_ical(value)
      value = string_value 'until', value
      if value =~ JCAL_DATE_TIME_REGEX
        value.gsub(/[-:]/, '')
      elsif value =~ JCAL_DATE_REGEX
        value.delete '-'
      else
        raise ArgumentError, "until value #{value.inspect} is neither a jCal DATE nor DATE-TIME"
      end
    end

  end
end
