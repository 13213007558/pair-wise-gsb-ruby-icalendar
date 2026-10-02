require 'spec_helper'
require 'json'

describe Icalendar::JcalParser do
  let(:fixture_path) { File.join File.dirname(__FILE__), 'fixtures', 'jcal_sample.json' }
  let(:source) { File.read fixture_path }
  let(:calendar) { Icalendar::Calendar.parse_jcal(source).first }
  let(:event) { calendar.events.first }

  describe 'parsing into the shared object graph' do
    it 'parses calendar properties' do
      expect(calendar.version).to eq '2.0'
      expect(calendar.prodid).to eq '-//Example Corp//jCal Sample//EN'
      expect(calendar.calscale).to eq 'GREGORIAN'
    end

    it 'parses event date-times' do
      expect(event.dtstart).to eq ::DateTime.new(2026, 10, 5, 9, 30, 0)
      expect(event.dtend).to eq ::DateTime.new(2026, 10, 5, 10, 30, 0)
    end

    it 'parses GEO as a structured float value' do
      expect(event.geo).to be_a Icalendar::Values::Helpers::Array
      expect(event.geo.map(&:class)).to eq [Icalendar::Values::Float, Icalendar::Values::Float]
      expect(event.geo.value_ical).to eq '37.386013;-122.082932'
    end

    it 'parses RDATE periods, explicit end and duration' do
      periods = event.rdate.first
      expect(periods.size).to eq 2
      expect(periods[0]).to be_a Icalendar::Values::Period
      expect(periods[0].explicit_end).to eq ::DateTime.new(2026, 10, 6, 10, 30, 0)
      expect(periods[1].duration.value_ical).to eq 'PT1H'
    end

    it 'parses RRULE as a structured recur value' do
      rrule = event.rrule.first
      expect(rrule).to be_a Icalendar::Values::Recur
      expect(rrule.frequency).to eq 'WEEKLY'
      expect(rrule.count).to eq 4
      expect(rrule.by_day).to eq %w[MO WE]
    end

    it 'preserves attendee parameters' do
      john, jane = event.attendee
      expect(john.ical_params['cn']).to eq ['John Doe']
      expect(john.ical_params['role']).to eq ['REQ-PARTICIPANT']
      expect(john.ical_params['partstat']).to eq ['ACCEPTED']
      expect(john.ical_params['rsvp']).to eq ['TRUE']
      expect(jane.ical_params['cn']).to eq ['Jane; Boss']
      expect(jane.ical_params['type']).to eq %w[INDIVIDUAL ROOM]
    end

    it 'parses multi-value text properties' do
      expect(event.categories.first.map(&:to_s)).to eq %w[MEETING PLANNING]
    end

    it 'parses nested components' do
      alarm = event.alarms.first
      expect(alarm).to be_a Icalendar::Alarm
      expect(alarm.trigger.value_ical).to eq '-PT15M'
    end

    it 'parses custom components' do
      custom = calendar.custom_component('x_my_component').first
      expect(custom.ical_name).to eq 'X-MY-COMPONENT'
      expect(custom.custom_property('x_inner').first).to eq 'nested value'
    end

    it 'keeps unknown-typed X- properties raw instead of guessing text' do
      raw = calendar.custom_property('x_custom_raw').first
      expect(raw).to be_a Icalendar::Values::Unknown
      expect(raw).not_to be_a Icalendar::Values::Text
      expect(raw.value).to eq 'opaque;value:with,separators'
    end

    it 'parses a stream of jCal components' do
      stream = "[#{JSON.parse(source).to_json}, #{JSON.parse(source).to_json}]"
      expect(Icalendar::Calendar.parse_jcal(stream).size).to eq 2
    end

    it 'round trips tzid parameters' do
      jcal = '["vcalendar",[["version",{},"text","2.0"],["prodid",{},"text","x"]],[["vevent",[["uid",{},"text","1"],["dtstamp",{},"date-time","2026-01-01T00:00:00Z"],["dtstart",{"tzid":"America/New_York"},"date-time","2026-01-05T09:00:00"]],[]]]]'
      cal = Icalendar::Calendar.parse_jcal(jcal).first
      expect(cal.events.first.dtstart.ical_params['tzid']).to eq ['America/New_York']
      expect(cal.to_jcal[2][0][1][2][1]).to eq('tzid' => 'America/New_York')
      expect(cal.to_ical).to include 'DTSTART;TZID=America/New_York:20260105T090000'
    end

    it 'round trips scalar value types' do
      jcal = '["vcalendar",[["version",{},"text","2.0"],["prodid",{},"text","x"],["x-flag",{},"boolean",true],["x-day",{},"date","2026-02-03"],["x-at",{},"time","10:11:12Z"],["x-off",{},"utc-offset","-05:30"]],[]]'
      cal = Icalendar::Calendar.parse_jcal(jcal).first
      expect(cal.to_jcal[1].drop(3)).to eq JSON.parse(jcal)[1].drop(2)
      ical = cal.to_ical
      expect(ical).to include 'X-FLAG;VALUE=BOOLEAN:TRUE'
      expect(ical).to include 'X-DAY;VALUE=DATE:20260203'
      expect(ical).to include 'X-AT;VALUE=TIME:101112Z'
      expect(ical).to include 'X-OFF;VALUE=UTC-OFFSET:-0530'
    end

    it 'round trips multi-value unknown properties' do
      jcal = '["vcalendar",[["version",{},"text","2.0"],["prodid",{},"text","x"],["x-multi",{},"unknown","a;b","c:d"]],[]]'
      cal = Icalendar::Calendar.parse_jcal(jcal).first
      expect(cal.to_jcal[1][3]).to eq ['x-multi', {}, 'unknown', 'a;b', 'c:d']
      expect(cal.to_ical).to include 'X-MULTI:a;b,c:d'
    end
  end

  describe 'jCal round trip' do
    it 'generates the same jCal document as is parsed' do
      expect(calendar.to_jcal).to eq JSON.parse(source)
    end

    it 'serializes to JSON text' do
      expect(JSON.parse(calendar.to_jcal.to_json)).to eq JSON.parse(source)
    end
  end

  describe 'jCal to iCalendar' do
    let(:ical) { calendar.to_ical }
    let(:unfolded) { ical.gsub(/\r\n[ \t]/, '') }

    it 'expresses the same calendar as ICS' do
      expect(unfolded).to include 'GEO:37.386013;-122.082932'
      expect(unfolded).to include 'RDATE;VALUE=PERIOD:20261006T093000Z/20261006T103000Z,20261007T093000Z/PT1H'
      expect(unfolded).to include 'ATTENDEE;CN=John Doe;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:john@example.com'
      expect(unfolded).to include 'ATTENDEE;CN="Jane; Boss";ROLE=OPT-PARTICIPANT;TYPE=INDIVIDUAL,ROOM:mailto:jane@example.com'
      expect(ical).to include 'RRULE:FREQ=WEEKLY;COUNT=4;BYDAY=MO,WE'
      expect(ical).to include 'CATEGORIES:MEETING,PLANNING'
      expect(ical).to include 'X-NUM-GUESTS;VALUE=INTEGER:5'
      expect(ical).to include 'X-CUSTOM-RAW:opaque;value:with,separators'
      expect(ical).to include 'BEGIN:X-MY-COMPONENT'
    end

    it 'produces ICS that parses back to the same event data' do
      reparsed = Icalendar::Calendar.parse(ical).first.events.first
      expect(reparsed.geo.value_ical).to eq '37.386013;-122.082932'
      expect(reparsed.rdate.first.map(&:value_ical)).to eq %w[20261006T093000Z/20261006T103000Z 20261007T093000Z/PT1H]
      expect(reparsed.attendee.first.ical_params['cn']).to eq ['John Doe']
      expect(reparsed.rrule.first.value_ical).to eq 'FREQ=WEEKLY;COUNT=4;BYDAY=MO,WE'
    end
  end

  describe 'iCalendar to jCal' do
    let(:ics) { File.read File.join(File.dirname(__FILE__), 'fixtures', 'single_event.ics') }
    let(:jcal) { Icalendar::Calendar.parse(ics).first.to_jcal }

    it 'converts components, properties and value types' do
      expect(jcal[0]).to eq 'vcalendar'
      event = jcal[2].find { |c| c[0] == 'vevent' }
      props = event[1].to_h { |p| [p[0], p] }
      expect(props['dtstart'][2]).to eq 'date-time'
      expect(props['dtstart'][3]).to match /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
      expect(props['summary'][2]).to eq 'text'
    end

    it 'round trips back through the jCal parser' do
      reparsed = Icalendar::Calendar.parse_jcal(JSON.generate([jcal])).first
      expect(reparsed.to_ical).to eq Icalendar::Calendar.parse(ics).first.to_ical
    end
  end

  describe 'error positions' do
    it 'points at line and column for malformed JSON' do
      expect { Icalendar::Calendar.parse_jcal("[\"vcalendar\",\n bad") }
        .to raise_error(Icalendar::Parser::ParseError, /line \d+ column \d+/)
    end

    it 'points at the JSON path of a malformed property' do
      bad = '["vcalendar", [["version"]], []]'
      expect { Icalendar::Calendar.parse_jcal(bad) }
        .to raise_error(Icalendar::Parser::ParseError, /\$\[1\]\[0\]/)
    end

    it 'points at the JSON path of a malformed component' do
      bad = '["vcalendar", [], [["vevent"]]]'
      expect { Icalendar::Calendar.parse_jcal(bad) }
        .to raise_error(Icalendar::Parser::ParseError, /\$\[2\]\[0\]/)
    end

    it 'points at the JSON path of an invalid value' do
      bad = '["vcalendar", [["version", {}, "text", "2.0"]], [["vevent", [["dtstart", {}, "date-time", "not-a-date"]], []]]]'
      expect { Icalendar::Calendar.parse_jcal(bad) }
        .to raise_error(Icalendar::Parser::ParseError, /\$\[2\]\[0\]\[1\]\[0\]/)
    end

    it 'rejects non-vcalendar roots' do
      expect { Icalendar::Calendar.parse_jcal('["vevent", [], []]') }
        .to raise_error(Icalendar::Parser::ParseError, /vcalendar/)
    end
  end
end
