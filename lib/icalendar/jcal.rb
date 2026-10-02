# frozen_string_literal: true

require 'json'

module Icalendar

  # Helpers for converting between iCalendar objects and RFC 7265 jCal
  # structures. A jCal document maps one-to-one to Ruby arrays, hashes and
  # scalars, so Icalendar::Jcal.dump returns plain Ruby objects that can be
  # serialized with JSON.generate, and Icalendar::JcalParser accepts anything
  # JSON.parse understands.
  module Jcal

    VALUE_TYPE_CLASSES = {
      'binary' => Icalendar::Values::Binary,
      'boolean' => Icalendar::Values::Boolean,
      'cal-address' => Icalendar::Values::CalAddress,
      'date' => Icalendar::Values::Date,
      'date-time' => Icalendar::Values::DateTime,
      'duration' => Icalendar::Values::Duration,
      'float' => Icalendar::Values::Float,
      'integer' => Icalendar::Values::Integer,
      'period' => Icalendar::Values::Period,
      'recur' => Icalendar::Values::Recur,
      'text' => Icalendar::Values::Text,
      'time' => Icalendar::Values::Time,
      'uri' => Icalendar::Values::Uri,
      'utc-offset' => Icalendar::Values::UtcOffset
    }.freeze

    def self.value_class(type)
      VALUE_TYPE_CLASSES[type.to_s.downcase]
    end

    # Component -> jCal

    def self.dump(component)
      [
        component.ical_name.downcase,
        properties_to_jcal(component),
        components_to_jcal(component)
      ]
    end

    def self.properties_to_jcal(component)
      (component.class.properties + component.custom_properties.keys).flat_map do |prop|
        value = component.property prop
        next [] if value.nil?
        default_type = component.class.default_property_types[prop]
        values = value.is_a?(::Array) ? value : [value]
        values.map { |v| property_to_jcal jcal_prop_name(prop), v, default_type }
      end
    end

    JCAL_PROP_NAME_GSUB_REGEX = /\Aip_/.freeze

    def self.jcal_prop_name(prop_name)
      prop_name.gsub(JCAL_PROP_NAME_GSUB_REGEX, '').tr('_', '-').downcase
    end

    def self.components_to_jcal(component)
      (component.class.components + component.custom_components.keys).flat_map do |component_name|
        component.send(component_name).map { |c| dump c }
      end
    end

    def self.property_to_jcal(name, value, default_type = nil)
      [name, params_to_jcal(value), jcal_value_type(value, default_type), *values_to_jcal(value)]
    end

    def self.jcal_value_type(value, default_type = nil)
      declared = value.ical_params['value']
      declared = declared.first if declared.is_a? ::Array
      (declared || value.value_type).downcase
    end

    def self.params_to_jcal(value)
      params = {}
      all_params(value).each do |key, param_value|
        next if key.to_s.downcase == 'value'
        vals = param_value.is_a?(::Array) ? param_value : [param_value]
        params[key.to_s.tr('_', '-').downcase] = vals.size == 1 ? vals.first.to_s : vals.map(&:to_s)
      end
      params
    end

    def self.all_params(value)
      return value.ical_params unless value.is_a? Icalendar::Values::Helpers::Array
      merged = {}
      value.ical_params.each { |k, v| merged[k] = v }
      value.value.each { |element| element.ical_params.each { |k, v| merged[k] = v } }
      merged
    end

    def self.values_to_jcal(value)
      if value.is_a? Icalendar::Values::Helpers::Array
        converted = value.value.map { |element| element_to_jcal element }
        # a semicolon-delimited list is a single structured value in jCal,
        # while comma-delimited values become separate array elements
        value.value_delimiter == ';' ? [converted] : converted
      else
        [value_to_jcal(value)]
      end
    end

    def self.element_to_jcal(element)
      if element.is_a? Icalendar::Values::Helpers::Array
        element.value.map { |e| element_to_jcal e }
      else
        value_to_jcal element
      end
    end

    def self.value_to_jcal(value)
      case jcal_value_type(value)
      when 'boolean' then value.value ? true : false
      when 'integer' then value.value.to_i
      when 'float' then value.value.to_f
      when 'date' then jcal_date value.value_ical
      when 'time' then jcal_time value.value_ical
      when 'date-time' then jcal_date_time value.value_ical
      when 'utc-offset' then jcal_utc_offset value.value_ical
      when 'duration' then value.value_ical
      when 'period' then jcal_period value.value_ical
      when 'recur' then recur_to_jcal value
      when 'binary' then value.value_ical
      else value.value.to_s
      end
    end

    JCAL_DATE_REGEX = /\A(\d{4})(\d{2})(\d{2})/.freeze
    JCAL_TIME_REGEX = /\A(\d{2})(\d{2})(\d{2})/.freeze
    JCAL_DATE_TIME_REGEX = /\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})/.freeze
    JCAL_UTC_OFFSET_REGEX = /\A([+-])(\d{2})(\d{2})(\d{2})?\z/.freeze
    JCAL_DURATION_PART_REGEX = /\A[+-]?P/i.freeze

    def self.jcal_date(ical)
      ical.sub JCAL_DATE_REGEX, '\\1-\\2-\\3'
    end

    def self.jcal_time(ical)
      ical.sub JCAL_TIME_REGEX, '\\1:\\2:\\3'
    end

    def self.jcal_date_time(ical)
      ical.sub JCAL_DATE_TIME_REGEX, '\\1-\\2-\\3T\\4:\\5:\\6'
    end

    def self.jcal_utc_offset(ical)
      ical.sub JCAL_UTC_OFFSET_REGEX do
        offset = "#{$1}#{$2}:#{$3}"
        $4.nil? ? offset : "#{offset}:#{$4}"
      end
    end

    def self.jcal_period(ical)
      ical.split('/').map do |part|
        part =~ JCAL_DURATION_PART_REGEX ? part : jcal_date_time(part)
      end.join '/'
    end

    RECUR_JCAL_LIST_KEYS = {
      'bysecond' => :by_second,
      'byminute' => :by_minute,
      'byhour' => :by_hour,
      'byday' => :by_day,
      'bymonthday' => :by_month_day,
      'byyearday' => :by_year_day,
      'byweekno' => :by_week_number,
      'bymonth' => :by_month,
      'bysetpos' => :by_set_position
    }.freeze

    def self.recur_to_jcal(value)
      recur = value.value
      result = {}
      result['freq'] = recur.frequency unless recur.frequency.nil?
      unless recur.until.nil?
        raw = recur.until.to_s
        result['until'] = raw.include?('T') ? jcal_date_time(raw) : jcal_date(raw)
      end
      result['count'] = recur.count unless recur.count.nil?
      result['interval'] = recur.interval unless recur.interval.nil?
      RECUR_JCAL_LIST_KEYS.each do |key, reader|
        list = recur.send reader
        result[key] = list unless list.nil?
      end
      result['wkst'] = recur.week_start unless recur.week_start.nil?
      result
    end

    # jCal -> iCalendar lexical forms, so the existing value classes can
    # parse jCal values exactly as they parse ICS values.

    def self.ics_lexical(type, value)
      case type.to_s.downcase
      when 'date', 'time', 'date-time'
        value.to_s.delete('-').delete(':')
      when 'utc-offset'
        value.to_s.delete(':')
      when 'period'
        value.to_s.split('/').map do |part|
          part =~ JCAL_DURATION_PART_REGEX ? part : part.delete('-').delete(':')
        end.join '/'
      when 'recur'
        recur_to_ics value
      when 'boolean'
        value.to_s.downcase == 'true' ? 'TRUE' : 'FALSE'
      else
        value.to_s
      end
    end

    RECUR_ICS_KEY_ORDER = %w(freq until count interval bysecond byminute byhour
                             byday bymonthday byyearday byweekno bymonth bysetpos wkst).freeze

    def self.recur_to_ics(hash)
      rendered = {}
      hash.each do |key, value|
        key = key.to_s.downcase
        value = ics_lexical(value.to_s.include?('T') ? 'date-time' : 'date', value) if key == 'until'
        rendered[key] = value.is_a?(::Array) ? value.join(',') : value.to_s
      end
      ordered = RECUR_ICS_KEY_ORDER.select { |key| rendered.key? key }
      (ordered + (rendered.keys - RECUR_ICS_KEY_ORDER)).map do |key|
        "#{key.upcase}=#{rendered[key]}"
      end.join ';'
    end

  end
end
