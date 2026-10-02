require 'spec_helper'
require 'json'

describe Icalendar::JcalParser do
  let(:source) { File.read File.join(File.dirname(__FILE__), 'fixtures', 'jcal_calendar.json') }
  let(:calendar) { described_class.new(source).parse.first }
  let(:event) { calendar.events.first }

  it 'parses the calendar component and its properties' do
    expect(calendar).to be_a Icalendar::Calendar
    expect(calendar.version).to eq '2.0'
    expect(calendar.prodid).to eq '-//Example Corp//jCal Sample//EN'
  end

  it 'parses nested components' do
    expect(event).to be_a Icalendar::Event
    expect(event.summary).to eq 'jCal sample event'
    expect(event.dtstart).to eq ::DateTime.new(2026, 10, 5, 9, 0, 0)
    expect(event.alarms.first.trigger.value_ical).to eq '-PT15M'
  end

  it 'parses structured values like GEO' do
    expect(event.geo).to be_a Icalendar::Values::Helpers::Array
    expect(event.geo.map(&:value)).to eq [37.386013, -122.082932]
    expect(event.geo.first).to be_a Icalendar::Values::Float
  end

  it 'parses multi-value RDATE periods with parameters' do
    rdate = event.rdate.first
    expect(rdate).to be_a Icalendar::Values::Helpers::Array
    expect(rdate.map(&:class)).to eq [Icalendar::Values::Period, Icalendar::Values::Period]
    expect(rdate.first.ical_params['tzid']).to eq ['US-Mountain']
    expect(rdate.first.period_start).to eq ::DateTime.new(2026, 10, 6, 9, 0, 0)
    expect(rdate.last.duration).to be_a Icalendar::Values::Duration
  end

  it 'parses property parameters on ATTENDEE' do
    attendee = event.attendee.first
    expect(attendee).to be_a Icalendar::Values::CalAddress
    expect(attendee.to_s).to eq 'mailto:john@example.com'
    expect(attendee.ical_params['cn']).to eq ['John Doe']
    expect(attendee.ical_params['role']).to eq ['REQ-PARTICIPANT']
    expect(attendee.ical_params['partstat']).to eq ['ACCEPTED']
    expect(attendee.ical_params['delegated-to']).to eq ['mailto:a@example.com', 'mailto:b@example.com']
  end

  it 'parses multi-value text properties' do
    expect(event.categories.first.map(&:value)).to eq %w(MEETING BUSINESS)
  end

  it 'types unknown X- properties from the jCal value type instead of guessing text' do
    guests = calendar.events.first.custom_property('x_num_guests').first
    expect(guests).to be_a Icalendar::Values::Integer
    expect(guests.value).to eq 5
  end

  it 'preserves unknown value types so they round-trip' do
    weird = event.custom_property('x_weird').first
    expect(weird.ical_params['value']).to eq ['X-CUSTOM-TYPE']
    expect(weird.value).to eq 'opaque-value'
  end

  it 'parses custom components' do
    custom = calendar.custom_component('x_my_component').first
    expect(custom).to_not be_nil
    expect(custom.ical_name).to eq 'X-MY-COMPONENT'
    expect(custom.custom_property('x_inner_prop').first).to eq 'nested'
  end

  it 'parses a stream of multiple components' do
    inner = JSON.parse(source)
    calendars = described_class.new(JSON.generate([inner, inner])).parse
    expect(calendars.size).to eq 2
    expect(calendars).to all(be_a Icalendar::Calendar)
  end

  describe 'jCal to ICS' do
    let(:ics) { calendar.to_ical.gsub(/\r\n /, '') }

    it 'expresses the same calendar as the jCal input' do
      expect(ics).to include "GEO:37.386013;-122.082932"
      expect(ics).to include "RDATE;VALUE=PERIOD;TZID=US-Mountain:20261006T090000/20261006T100000,20261007T090000/PT1H"
      expect(ics).to include 'ATTENDEE;CN=John Doe;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;DELEGATED-TO="mailto:a@example.com","mailto:b@example.com":mailto:john@example.com'
      expect(ics).to include "CATEGORIES:MEETING,BUSINESS"
      expect(ics).to include "X-NUM-GUESTS;VALUE=INTEGER:5"
      expect(ics).to include "X-WEIRD;VALUE=X-CUSTOM-TYPE:opaque-value"
      expect(ics).to include "BEGIN:X-MY-COMPONENT"
      expect(ics).to include "BEGIN:VALARM"
    end
  end

  describe 'error reporting' do
    it 'reports JSON syntax errors with their position' do
      expect { described_class.new('["vcalendar", [], [').parse }
        .to raise_error(Icalendar::JcalParser::ParseError, /Invalid jCal JSON:.*line \d+ column \d+/)
    end

    it 'rejects documents that are not components' do
      expect { described_class.new('{"vcalendar": true}').parse }
        .to raise_error(Icalendar::JcalParser::ParseError, /Invalid jCal at \$/)
    end

    it 'points at the JSON path of malformed components' do
      expect { described_class.new('["vcalendar", [], [["vevent", "oops", []]]]').parse }
        .to raise_error(Icalendar::JcalParser::ParseError, /\$\.components\[0\]\(vevent\)/)
    end

    it 'points at the JSON path of malformed properties' do
      expect { described_class.new('["vcalendar", [["version"]], []]').parse }
        .to raise_error(Icalendar::JcalParser::ParseError, /\$\.properties\[0\]\(version\)/)
    end

    it 'points at the JSON path of invalid values' do
      jcal = '["vcalendar", [], [["vevent", [["dtstart", {}, "date-time", "not-a-date"]], []]]]'
      expect { described_class.new(jcal).parse }
        .to raise_error(Icalendar::JcalParser::ParseError, /\$\.components\[0\]\(vevent\)\.properties\[0\]\(dtstart\)/)
    end

    it 'points at the JSON path of wrongly typed values' do
      jcal = '["vcalendar", [], [["vevent", [["rrule", {}, "recur", "FREQ=DAILY"]], []]]]'
      expect { described_class.new(jcal).parse }
        .to raise_error(Icalendar::JcalParser::ParseError, /values\[0\]/)
    end
  end
end

describe 'Component jCal support' do
  let(:source) { File.read File.join(File.dirname(__FILE__), 'fixtures', 'jcal_calendar.json') }
  let(:calendar) { Icalendar::Calendar.parse_jcal(source).first }

  describe '.parse_jcal' do
    it 'parses jCal into the component graph' do
      expect(calendar).to be_a Icalendar::Calendar
      expect(calendar.events.first.summary).to eq 'jCal sample event'
    end
  end

  describe '#to_jcal' do
    let(:jcal) { calendar.to_jcal }

    it 'produces the RFC 7265 structure' do
      expect(jcal[0]).to eq 'vcalendar'
      expect(jcal[1]).to include ['version', {}, 'text', '2.0']
      expect(jcal[2].first[0]).to eq 'vevent'
    end

    it 'serializes structured values as nested arrays' do
      geo = jcal[2].first[1].find { |prop| prop[0] == 'geo' }
      expect(geo).to eq ['geo', {}, 'float', [37.386013, -122.082932]]
    end

    it 'serializes multi-value properties as multiple values' do
      categories = jcal[2].first[1].find { |prop| prop[0] == 'categories' }
      expect(categories).to eq ['categories', {}, 'text', 'MEETING', 'BUSINESS']
    end

    it 'serializes parameters, keeping multi-value parameters as arrays' do
      attendee = jcal[2].first[1].find { |prop| prop[0] == 'attendee' }
      expect(attendee[1]['cn']).to eq 'John Doe'
      expect(attendee[1]['delegated-to']).to eq ['mailto:a@example.com', 'mailto:b@example.com']
    end

    it 'serializes periods with jCal date-time separators' do
      rdate = jcal[2].first[1].find { |prop| prop[0] == 'rdate' }
      expect(rdate[2]).to eq 'period'
      expect(rdate[3]).to eq '2026-10-06T09:00:00/2026-10-06T10:00:00'
      expect(rdate[4]).to eq '2026-10-07T09:00:00/PT1H'
    end

    it 'keeps the declared type of unknown X- properties' do
      guests = jcal[2].first[1].find { |prop| prop[0] == 'x-num-guests' }
      expect(guests).to eq ['x-num-guests', {}, 'integer', 5]
      weird = jcal[2].first[1].find { |prop| prop[0] == 'x-weird' }
      expect(weird).to eq ['x-weird', {}, 'x-custom-type', 'opaque-value']
    end

    it 'keeps custom components' do
      custom = jcal[2].find { |component| component[0] == 'x-my-component' }
      expect(custom).to eq ['x-my-component', [['x-inner-prop', {}, 'text', 'nested']], []]
    end
  end

  describe '#to_jcal_json' do
    it 'serializes to a JSON document' do
      expect(JSON.parse(calendar.to_jcal_json)).to eq calendar.to_jcal
    end
  end

  describe 'round trips' do
    it 'jCal -> objects -> jCal -> objects produces the same ICS' do
      reparsed = Icalendar::JcalParser.new(calendar.to_jcal_json).parse.first
      expect(reparsed.to_ical).to eq calendar.to_ical
    end

    it 'jCal -> objects -> jCal is stable' do
      again = Icalendar::JcalParser.new(calendar.to_jcal_json).parse.first
      expect(again.to_jcal).to eq calendar.to_jcal
    end

    it 'ICS -> objects -> jCal -> objects produces the same ICS' do
      ics = File.read File.join(File.dirname(__FILE__), 'fixtures', 'single_event.ics')
      from_ics = Icalendar::Calendar.parse(ics).first
      reparsed = Icalendar::JcalParser.new(from_ics.to_jcal_json).parse.first
      expect(reparsed.to_ical).to eq ics
    end
  end
end
