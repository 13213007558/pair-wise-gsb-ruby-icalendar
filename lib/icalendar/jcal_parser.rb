# frozen_string_literal: true

require 'json'
require 'icalendar/parser'

module Icalendar

  # JcalParser parses jCal (RFC 7265) JSON documents into the same
  # Calendar/Event/Value object graph that Icalendar::Parser produces
  # for iCalendar (ICS) input.
  class JcalParser < Parser

    def initialize(source, strict = false, verbose = false)
      @source = source
      @strict = strict
      @verbose = verbose
      @parse_depth = 0
      @timezone_store = TimezoneStore.new
    end

    def parse
      document = begin
        JSON.parse source_text
      rescue JSON::ParserError => e
        raise ParseError, "Invalid jCal JSON: #{e.message}"
      end
      roots, paths = root_nodes document
      roots.each_with_index.map do |node, index|
        path = paths[index]
        name = component_name node, path
        component = component_class.new
        unless name == component.ical_name.downcase
          raise ParseError, "Invalid jCal at #{path}: expected a #{component.ical_name.downcase} component, got #{name.inspect}"
        end
        parse_component component, node, path
      end
    end

    private

    def source_text
      if source.respond_to? :read
        source.read
      elsif source.respond_to? :to_s
        source.to_s
      else
        msg = 'Icalendar::JcalParser.new must be called with a String or IO object'
        Icalendar.fatal msg
        fail ArgumentError, msg
      end
    end

    # A jCal stream is a JSON array of jCal components; a single jCal
    # component is an array whose first element is the component name.
    def root_nodes(document)
      if document.is_a?(::Array) && document.first.is_a?(String)
        [[document], ['$']]
      elsif document.is_a? ::Array
        [document, document.each_index.map { |i| "$[#{i}]" }]
      else
        raise ParseError, "Invalid jCal at $: expected a component array, got #{document.inspect[0, 120]}"
      end
    end

    def component_name(node, path)
      unless node.is_a?(::Array) && node.size == 3 &&
             node[0].is_a?(String) && node[1].is_a?(::Array) && node[2].is_a?(::Array)
        raise ParseError, "Invalid jCal component at #{path}: expected [name, properties, components], got #{node.inspect[0, 120]}"
      end
      node[0].downcase
    end

    COMPONENT_KLASS_NAME_GSUB_REGEX = /\AV/.freeze

    def parse_component(component, node, path)
      self.parse_depth += 1
      raise ParseError.new("jCal nested too deeply at #{path}") if parse_depth > parse_depth_limit
      _, properties, components = node
      properties.each_with_index do |property, index|
        parse_jcal_property component, property, "#{path}[1][#{index}]"
      end
      components.each_with_index do |child, index|
        child_path = "#{path}[2][#{index}]"
        child_name = component_name child, child_path
        klass_name = child_name.upcase.gsub(COMPONENT_KLASS_NAME_GSUB_REGEX, '').gsub('-', '_').downcase.capitalize
        Icalendar.logger.debug "Adding component #{klass_name}"
        if Object.const_defined? "Icalendar::#{klass_name}"
          component.add_component parse_component(Object.const_get("Icalendar::#{klass_name}").new, child, child_path)
        elsif Object.const_defined? "Icalendar::Timezone::#{klass_name}"
          component.add_component parse_component(Object.const_get("Icalendar::Timezone::#{klass_name}").new, child, child_path)
        else
          component.add_custom_component klass_name, parse_component(Component.new(klass_name.downcase, child_name.upcase), child, child_path)
        end
      end
      timezone_store.store(component) if component.is_a? Icalendar::Timezone
      self.parse_depth -= 1
      component
    end

    def parse_jcal_property(component, node, path)
      unless node.is_a?(::Array) && node.size >= 4 &&
             node[0].is_a?(String) && node[1].is_a?(Hash) && node[2].is_a?(String)
        raise ParseError, "Invalid jCal property at #{path}: expected [name, params, type, values...], got #{node.inspect[0, 120]}"
      end
      name, params, type, *values = node
      type = type.downcase
      ical_params = jcal_params_to_ical params, path
      if type != 'unknown' && Jcal::KNOWN_VALUE_TYPES.include?(type)
        ical_string = begin
          Jcal.values_to_ical_string type, values, name.downcase
        rescue ArgumentError => e
          raise ParseError, "Invalid jCal property #{name.inspect} at #{path}: #{e.message}"
        end
        parse_property component, {
          name: name.downcase.gsub('-', '_'),
          params: ical_params.merge('value' => [type.upcase]),
          value: ical_string
        }
      else
        # Unknown value types (including unregistered ones) are kept raw so
        # X- properties round trip without being guessed as TEXT.
        raw = values.map do |value|
          unless value.is_a? String
            raise ParseError, "Invalid jCal property #{name.inspect} at #{path}: unknown-typed values must be strings, got #{value.inspect}"
          end
          value
        end
        assign_unknown component, name.downcase.gsub('-', '_'), Icalendar::Values::Unknown.new(raw.size == 1 ? raw.first : raw, ical_params)
      end
    end

    def assign_unknown(component, prop_name, value)
      prop_name = "ip_#{prop_name}" if %w(class method name).include? prop_name
      if component.class.single_properties.include? prop_name
        component.send "#{prop_name}=", value
      elsif component.class.multiple_properties.include? prop_name
        component.send "append_#{prop_name}", value
      else
        component.append_custom_property prop_name, value
      end
    end

    def jcal_params_to_ical(params, path)
      params.each_with_object({}) do |(key, value), ical_params|
        unless key.is_a? String
          raise ParseError, "Invalid jCal parameter at #{path}: parameter names must be strings, got #{key.inspect}"
        end
        ical_params[key.downcase] = if value.is_a? ::Array
          value.map { |element| jcal_param_scalar element, path }
        else
          [jcal_param_scalar(value, path)]
        end
      end
    end

    def jcal_param_scalar(value, path)
      case value
      when String then value
      when ::Numeric, true, false then value.to_s
      else
        raise ParseError, "Invalid jCal parameter value at #{path}: expected a string, got #{value.inspect}"
      end
    end

  end
end
