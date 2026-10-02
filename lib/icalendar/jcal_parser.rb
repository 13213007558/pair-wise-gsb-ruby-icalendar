# frozen_string_literal: true

require 'json'
require 'icalendar/jcal'
require 'icalendar/timezone_store'

module Icalendar

  # Parses RFC 7265 jCal JSON into the same Calendar/Event/Value object
  # graph that Icalendar::Parser builds from ICS, so both formats share a
  # single data flow.
  class JcalParser
    attr_reader :source, :strict, :timezone_store

    def initialize(source, strict = false, verbose = false)
      @source = if source.respond_to? :read
        source.read
      elsif source.respond_to? :to_s
        source.to_s
      else
        msg = 'Icalendar::JcalParser.new must be called with a String or IO object'
        Icalendar.fatal msg
        fail ArgumentError, msg
      end
      @strict = strict
      @verbose = verbose
      @timezone_store = TimezoneStore.new
    end

    def parse
      data = begin
        JSON.parse source
      rescue JSON::ParserError => e
        raise ParseError, "Invalid jCal JSON: #{e.message}"
      end
      nodes = component_node?(data) ? [data] : data
      unless nodes.is_a? ::Array
        raise ParseError, 'Invalid jCal at $: expected a component or an array of components'
      end
      single = component_node?(data)
      nodes.each_with_index.map do |node, index|
        parse_component(node, [single ? '$' : "$[#{index}]"]).component
      end
    end

    def strict?
      !!@strict
    end

    def verbose?
      !!@verbose
    end

    private

    ParsedComponent = Struct.new :component, :klass_name, :custom

    def component_node?(node)
      node.is_a?(::Array) && node.size == 3 &&
        node[0].is_a?(String) && node[1].is_a?(::Array) && node[2].is_a?(::Array)
    end

    PARSE_COMPONENT_KLASS_NAME_GSUB_REGEX = /\AV/.freeze

    def parse_component(node, path)
      unless component_node? node
        raise ParseError, "Invalid jCal component at #{format_path path}: expected [name, properties, components]"
      end
      name, properties, components = node
      ical_name = name.upcase
      klass_name = ical_name.gsub(PARSE_COMPONENT_KLASS_NAME_GSUB_REGEX, '').gsub('-', '_').downcase.capitalize
      component, custom = instantiate_component klass_name, ical_name

      properties.each_with_index do |property_node, index|
        parse_property component, property_node, path + [".properties[#{index}](#{node_label property_node})"]
      end

      components.each_with_index do |component_node, index|
        child = parse_component component_node, path + [".components[#{index}](#{node_label component_node})"]
        if child.custom
          component.add_custom_component child.klass_name, child.component
        else
          component.add_component child.component
        end
      end

      timezone_store.store component if klass_name == 'Timezone'
      ParsedComponent.new component, klass_name, custom
    end

    def instantiate_component(klass_name, ical_name)
      if Object.const_defined? "Icalendar::#{klass_name}"
        [Object.const_get("Icalendar::#{klass_name}").new, false]
      elsif Object.const_defined? "Icalendar::Timezone::#{klass_name}"
        [Object.const_get("Icalendar::Timezone::#{klass_name}").new, false]
      else
        [Component.new(klass_name.downcase, ical_name), true]
      end
    end

    def parse_property(component, node, path)
      unless node.is_a?(::Array) && node.size >= 4 &&
             node[0].is_a?(String) && node[1].is_a?(Hash) && node[2].is_a?(String)
        raise ParseError, "Invalid jCal property at #{format_path path}: expected [name, parameters, type, *values]"
      end
      name, params, type, *values = node
      prop_name = name.downcase.gsub '-', '_'
      prop_name = "ip_#{prop_name}" if %w(class method name).include? prop_name
      type = type.downcase
      params = normalize_params params
      params.delete 'value'
      klass = value_class_for component, prop_name, type, params
      prop_value = build_value klass, type, params, values, path
      assign_property component, prop_name, prop_value
    end

    def normalize_params(params)
      normalized = {}
      params.each do |key, value|
        values = value.is_a?(::Array) ? value : [value]
        normalized[key.to_s.downcase] = values.map(&:to_s)
      end
      normalized
    end

    def value_class_for(component, prop_name, type, params)
      default = component.class.default_property_types[prop_name]
      klass = Jcal.value_class type
      if klass.nil?
        # Unknown value type: keep the declared token on the VALUE parameter
        # so it round-trips instead of being silently treated as text.
        params['value'] = [type.upcase]
        default
      elsif default.value_type.downcase == type
        default
      else
        klass
      end
    end

    def build_value(klass, type, params, values, path)
      context = { timezone_store: timezone_store }
      converted = values.each_with_index.map do |value, index|
        convert_value type, value, path + [".values[#{index}]"]
      end
      if converted.size == 1
        first = converted.first
        if first.is_a? ::Array
          Icalendar::Values::Helpers::Array.new first, klass, params, context.merge(delimiter: ';')
        else
          klass.new first, params, context
        end
      else
        elements = converted.map do |element|
          if element.is_a? ::Array
            Icalendar::Values::Helpers::Array.new element, klass, params, context.merge(delimiter: ';')
          else
            element
          end
        end
        Icalendar::Values::Helpers::Array.new elements, klass, params, context.merge(delimiter: ',')
      end
    rescue ArgumentError => e
      raise ParseError, "Invalid jCal value at #{format_path path}: #{e.message}"
    end

    def convert_value(type, value, path)
      if value.is_a? ::Array
        value.each_with_index.map { |element, index| scalar_value type, element, path + ["[#{index}]"] }
      else
        scalar_value type, value, path
      end
    end

    def scalar_value(type, value, path)
      if type == 'recur'
        unless value.is_a? Hash
          raise ParseError, "Invalid jCal value at #{format_path path}: recur values must be objects"
        end
      elsif !value.is_a?(String) && !value.is_a?(Numeric) && value != true && value != false
        raise ParseError, "Invalid jCal value at #{format_path path}: unexpected #{value.class}"
      end
      Jcal.ics_lexical type, value
    end

    def assign_property(component, prop_name, prop_value)
      if component.class.multiple_properties.include? prop_name
        component.send "append_#{prop_name}", prop_value
      else
        component.send "#{prop_name}=", prop_value
      end
    rescue NoMethodError => nme
      raise nme if strict?
      Icalendar.logger.warn "No method for property #{prop_name} on component #{component}. Appending to custom." if verbose?
      component.append_custom_property prop_name, prop_value
    end

    def node_label(node)
      node.is_a?(::Array) && node[0].is_a?(String) ? node[0] : 'invalid'
    end

    def format_path(path)
      path.join
    end

    class ParseError < RuntimeError
    end
  end
end
