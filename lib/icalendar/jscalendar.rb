# frozen_string_literal: true

require 'json'
require 'date'

module Icalendar

  # RFC 8984 (JSCalendar) adapter.
  #
  # Converts a single Icalendar::Event to and from a JSCalendar Event
  # represented as a plain Ruby Hash (JSON-serializable). Covers the event
  # itself plus its participants, schedule (floating, zoned and all-day),
  # alerts, recurrence rules and recurrence exceptions.
  #
  # Properties that cannot be expressed in the target format are never
  # dropped silently: they are either preserved as extension data or
  # reported as lost, item by item, through an Icalendar::JSCalendar::Report.
  #
  #   report = Icalendar::JSCalendar::Report.new
  #   js = Icalendar::JSCalendar.event_to_jscalendar(event, report: report)
  #   event = Icalendar::JSCalendar.event_from_jscalendar(js, report: report)
  module JSCalendar

    # Prefix used for vendor extension properties, as encouraged by
    # RFC 8984 section 1.5 for data that has no JSCalendar counterpart.
    EXTENSION_PREFIX = 'icalendar:'

    # JSCalendar key (on an Event) under which unmapped iCalendar
    # properties are preserved.
    PRESERVED_PROPERTIES_KEY = "#{EXTENSION_PREFIX}properties"

    # iCalendar custom property used to preserve unmapped JSCalendar keys.
    PRESERVED_JSCALENDAR_PROPERTY = 'x-jscalendar-unmapped'

    def self.event_to_jscalendar(event, report: Report.new)
      Exporter.new(event, report).to_h
    end

    def self.event_from_jscalendar(jscalendar, report: Report.new)
      Importer.new(jscalendar, report).to_event
    end

  end
end

require 'icalendar/jscalendar/report'
require 'icalendar/jscalendar/helpers'
require 'icalendar/jscalendar/exporter'
require 'icalendar/jscalendar/importer'
