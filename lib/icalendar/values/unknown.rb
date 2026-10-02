# frozen_string_literal: true

module Icalendar
  module Values

    # Unknown represents a property value whose type is not known, e.g. an
    # X- property carried through jCal (RFC 7265) with the "unknown" value
    # type. The raw value is preserved verbatim so it can round trip through
    # jCal and iCalendar without being guessed as TEXT.
    class Unknown < Value

      def value_ical
        value.is_a?(::Array) ? value.join(',') : value.to_s
      end

      private

      # VALUE=UNKNOWN is not a real iCalendar parameter; the raw value is
      # emitted as-is.
      def needs_value_type?(default_type)
        false
      end

    end

  end
end
