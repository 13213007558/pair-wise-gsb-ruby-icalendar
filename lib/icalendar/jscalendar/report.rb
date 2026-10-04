# frozen_string_literal: true

module Icalendar
  module JSCalendar

    # Collects, item by item, what happened to properties that have no
    # direct counterpart in the target format. Every entry is either
    # :preserved (kept as extension data) or :lost (no representation
    # exists); nothing is dropped silently.
    class Report
      include Enumerable

      Entry = Struct.new(:direction, :property, :action, :detail, keyword_init: true) do
        def preserved?
          action == :preserved
        end

        def lost?
          action == :lost
        end

        def to_s
          "#{direction}: #{property} #{action}#{detail.nil? ? '' : " (#{detail})"}"
        end
      end

      attr_reader :entries

      def initialize
        @entries = []
      end

      def add(direction, property, action, detail = nil)
        entries << Entry.new(direction: direction, property: property, action: action, detail: detail)
      end

      def each(&block)
        entries.each(&block)
      end

      def preserved
        entries.select(&:preserved?)
      end

      def lost
        entries.select(&:lost?)
      end

      def empty?
        entries.empty?
      end
    end

  end
end
