require 'spec_helper'
require 'json'
require 'tzinfo'

# Use the bundled tzinfo-data gem (local, fixed timezone data) instead of
# whatever zoneinfo the host system happens to provide.
TZInfo::DataSource.set(:ruby)

describe Icalendar::JSCalendar do
  let(:report) { Icalendar::JSCalendar::Report.new }

  def parse_event(ics)
    Icalendar::Calendar.parse(ics).first.events.first
  end

  def round_trip(event)
    js = Icalendar::JSCalendar.event_to_jscalendar event, report: report
    # pass through JSON to prove the output is plain JSON-serializable data
    Icalendar::JSCalendar.event_from_jscalendar JSON.parse(JSON.generate(js)), report: report
  end

  # ical_params values may be plain scalars or single-element arrays
  # depending on which code path normalized them
  def param_value(params, key)
    value = params[key]
    value.is_a?(Array) ? value.first : value
  end

  let(:full_ics) do
    <<~ICS
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:jscalendar-spec
      BEGIN:VEVENT
      DTSTAMP:20260101T000000Z
      UID:stable-uid-123
      DTSTART;TZID=America/New_York:20261004T090000
      DTEND;TZID=America/New_York:20261004T103000
      SUMMARY:Weekly sync
      STATUS:CONFIRMED
      CATEGORIES:WORK,SYNC
      ORGANIZER;CN=Boss:mailto:boss@example.com
      ATTENDEE;CN=Joe;ROLE=OPT-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:joe@example.com
      ATTENDEE;CN=Guest;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION:mailto:guest@example.com
      RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=20261231T140000Z
      EXDATE;TZID=America/New_York:20261007T090000
      BEGIN:VALARM
      ACTION:DISPLAY
      TRIGGER:-PT15M
      DESCRIPTION:Reminder
      END:VALARM
      END:VEVENT
      END:VCALENDAR
    ICS
  end

  describe 'exporting a single event' do
    subject(:js) { Icalendar::JSCalendar.event_to_jscalendar parse_event(full_ics), report: report }

    it 'keeps the stable uid' do
      expect(js['uid']).to eq 'stable-uid-123'
      expect(js['@type']).to eq 'Event'
    end

    it 'is deterministic' do
      again = Icalendar::JSCalendar.event_to_jscalendar parse_event(full_ics)
      expect(JSON.generate(js)).to eq JSON.generate(again)
    end

    it 'exports the schedule with a named timezone' do
      expect(js['start']).to eq '2026-10-04T09:00:00'
      expect(js['timeZone']).to eq 'America/New_York'
      expect(js['duration']).to eq 'PT1H30M'
      expect(js).not_to have_key 'showWithoutTime'
    end

    it 'pins the local start to a fixed UTC instant using local timezone data' do
      zone = TZInfo::Timezone.get js['timeZone']
      local = DateTime.strptime js['start'], '%Y-%m-%dT%H:%M:%S'
      expect(zone.local_to_utc(local)).to eq Time.utc(2026, 10, 4, 13, 0, 0)
    end

    it 'exports organizer and attendees as participants' do
      owner = js['participants']['mailto:boss@example.com']
      expect(owner['roles']).to eq('owner' => true)
      expect(owner['name']).to eq 'Boss'
      expect(owner['sendTo']).to eq('imip' => 'mailto:boss@example.com')

      joe = js['participants']['mailto:joe@example.com']
      expect(joe['roles']).to eq('attendee' => true, 'optional' => true)
      expect(joe['participationStatus']).to eq 'accepted'
      expect(joe['expectReply']).to eq true

      guest = js['participants']['mailto:guest@example.com']
      expect(guest['roles']).to eq('attendee' => true)
      expect(guest['participationStatus']).to eq 'needs-action'
    end

    it 'exports the alarm as an alert' do
      alert = js['alerts']['alert-1']
      expect(alert['trigger']).to eq('@type' => 'OffsetTrigger', 'offset' => '-PT15M', 'relativeTo' => 'start')
      expect(alert['action']).to eq 'display'
    end

    it 'exports the recurrence rule' do
      expect(js['recurrenceRules']).to eq [
        { 'frequency' => 'weekly', 'until' => '2026-12-31T09:00:00',
          'byDay' => [{ 'day' => 'mo' }, { 'day' => 'we' }] }
      ]
    end

    it 'exports the exception as an excluded recurrence override' do
      expect(js['recurrenceOverrides']).to eq '2026-10-07T09:00:00' => { 'excluded' => true }
    end

    it 'exports scalars' do
      expect(js['title']).to eq 'Weekly sync'
      expect(js['status']).to eq 'confirmed'
      expect(js['keywords']).to eq('WORK' => true, 'SYNC' => true)
    end
  end

  describe 'round trip' do
    it 'keeps the event instance meaning' do
      event = parse_event full_ics
      back = round_trip event

      expect(back.uid).to eq 'stable-uid-123'
      expect(back.summary).to eq 'Weekly sync'
      expect(back.status).to eq 'CONFIRMED'
      expect(back.dtstart.value_ical).to eq '20261004T090000'
      expect(param_value(back.dtstart.ical_params, 'tzid')).to eq 'America/New_York'
      expect(back.dtend.value_ical).to eq '20261004T103000'
      expect(back.organizer.to_s).to eq 'mailto:boss@example.com'
      expect(back.attendee.map(&:to_s)).to contain_exactly 'mailto:joe@example.com', 'mailto:guest@example.com'

      joe = back.attendee.find { |a| a.to_s == 'mailto:joe@example.com' }
      expect(joe.ical_params['role']).to eq 'OPT-PARTICIPANT'
      expect(joe.ical_params['partstat']).to eq 'ACCEPTED'
      expect(joe.ical_params['rsvp']).to eq 'TRUE'
      expect(joe.ical_params['cn']).to eq 'Joe'

      expect(back.rrule.first.value_ical).to eq 'FREQ=WEEKLY;UNTIL=20261231T140000Z;BYDAY=MO,WE'
      expect(back.exdate.first.value_ical).to eq '20261007T090000'
      expect(param_value(back.exdate.first.ical_params, 'tzid')).to eq 'America/New_York'

      alarm = back.alarms.first
      expect(alarm.action).to eq 'DISPLAY'
      expect(alarm.trigger.value_ical).to eq '-PT15M'
      expect(alarm.description).to eq 'Reminder'
    end

    it 'round trips a UTC event' do
      event = Icalendar::Event.new
      event.dtstart = Icalendar::Values::DateTime.new '20261004T090000Z'
      event.dtend = Icalendar::Values::DateTime.new '20261004T100000Z'
      back = round_trip event
      expect(back.dtstart.value_ical).to eq '20261004T090000Z'
      expect(back.dtend.value_ical).to eq '20261004T100000Z'
    end
  end

  describe 'floating time' do
    subject(:js) do
      event = Icalendar::Event.new
      event.dtstart = DateTime.new 2026, 10, 4, 9, 0, 0
      event.dtend = DateTime.new 2026, 10, 4, 10, 0, 0
      Icalendar::JSCalendar.event_to_jscalendar event
    end

    it 'has no timeZone' do
      expect(js['start']).to eq '2026-10-04T09:00:00'
      expect(js).not_to have_key 'timeZone'
      expect(js['duration']).to eq 'PT1H'
    end

    it 'round trips as floating time' do
      back = Icalendar::JSCalendar.event_from_jscalendar js
      expect(back.dtstart.value_ical).to eq '20261004T090000'
      expect(back.dtstart.ical_params['tzid']).to be_nil
      expect(back.dtend.value_ical).to eq '20261004T100000'
    end
  end

  describe 'all-day events' do
    let(:event) do
      Icalendar::Event.new.tap do |event|
        event.dtstart = Icalendar::Values::Date.new '20261004'
        event.dtend = Icalendar::Values::Date.new '20261006'
        event.rrule = ['FREQ=DAILY;COUNT=5']
        event.append_exdate Icalendar::Values::Date.new '20261005'
      end
    end

    it 'exports showWithoutTime with a day duration' do
      js = Icalendar::JSCalendar.event_to_jscalendar event
      expect(js['start']).to eq '2026-10-04T00:00:00'
      expect(js['showWithoutTime']).to be true
      expect(js['duration']).to eq 'P2D'
      expect(js['recurrenceOverrides']).to eq '2026-10-05T00:00:00' => { 'excluded' => true }
    end

    it 'round trips dates and the single exception' do
      back = round_trip event
      expect(back.dtstart).to be_a Icalendar::Values::Date
      expect(back.dtstart.value_ical).to eq '20261004'
      expect(back.dtend.value_ical).to eq '20261006'
      expect(back.exdate.first).to be_a Icalendar::Values::Date
      expect(back.exdate.first.value_ical).to eq '20261005'
      expect(back.rrule.first.value_ical).to eq 'FREQ=DAILY;COUNT=5'
    end
  end

  describe 'loss and preservation reporting' do
    let(:event) do
      parse_event <<~ICS
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:jscalendar-spec
        BEGIN:VEVENT
        DTSTAMP:20260101T000000Z
        UID:report-1
        DTSTART:20261004T090000Z
        SUMMARY:Report me
        PRIORITY:2
        X-CUSTOM-THING:hello
        ATTENDEE;X-VENDOR=abc:mailto:a@example.com
        BEGIN:VALARM
        ACTION:AUDIO
        TRIGGER:-PT5M
        REPEAT:3
        DURATION:PT10M
        ATTACH:http://example.com/bell.mp3
        END:VALARM
        END:VEVENT
        END:VCALENDAR
      ICS
    end

    it 'preserves unmapped iCalendar properties as extension data and reports them' do
      js = Icalendar::JSCalendar.event_to_jscalendar event, report: report
      names = js['icalendar:properties'].map { |entry| entry['name'] }
      expect(names).to include 'DTSTAMP', 'PRIORITY', 'X-CUSTOM-THING'
      expect(report.preserved.map(&:property)).to include 'PRIORITY', 'X-CUSTOM-THING', 'participant parameter X-VENDOR'
      expect(report.lost).to be_empty
    end

    it 'preserves unmapped alarm attributes' do
      js = Icalendar::JSCalendar.event_to_jscalendar event, report: report
      alert = js['alerts']['alert-1']
      expect(alert['icalendar:action']).to eq 'AUDIO'
      expect(alert['icalendar:repeat']).to eq 3
      expect(alert['icalendar:duration']).to eq 'PT10M'
      expect(alert['icalendar:attach']).to eq ['http://example.com/bell.mp3']
      expect(report.preserved.map(&:property)).to include 'VALARM ACTION', 'VALARM REPEAT', 'VALARM DURATION', 'VALARM ATTACH'
    end

    it 'restores preserved properties on the way back' do
      back = round_trip event
      expect(back.priority).to eq 2
      expect(back.custom_property('x_custom_thing').first.to_s).to eq 'hello'
      expect(back.dtstamp.value_ical).to eq '20260101T000000Z'
      alarm = back.alarms.first
      expect(alarm.action).to eq 'AUDIO'
      expect(alarm.repeat).to eq 3
      expect(alarm.duration.value_ical).to eq 'PT10M'
      expect(param_value(back.attendee.first.ical_params, 'x-vendor')).to eq 'abc'
    end

    it 'preserves unmapped JSCalendar keys and restores them on re-export' do
      js = {
        '@type' => 'Event', 'uid' => 'js-1', 'start' => '2026-10-04T09:00:00',
        'links' => { 'link-1' => { '@type' => 'Link', 'href' => 'https://example.com', 'rel' => 'about' } },
        'example.com:custom' => { 'anything' => true }
      }
      event = Icalendar::JSCalendar.event_from_jscalendar js, report: report
      expect(report.preserved.map(&:property)).to include 'links', 'example.com:custom'

      exported = Icalendar::JSCalendar.event_to_jscalendar event
      expect(exported['links']).to eq js['links']
      expect(exported['example.com:custom']).to eq js['example.com:custom']
    end

    it 'reports properties that cannot be preserved' do
      js = {
        '@type' => 'Event', 'uid' => 'js-2', 'start' => '2026-10-04T09:00:00',
        'recurrenceRules' => [{ 'frequency' => 'monthly', 'rscale' => 'chinese', 'skip' => 'backward' }],
        'participants' => { 'p1' => { '@type' => 'Participant', 'roles' => { 'attendee' => true },
                                      'sendTo' => { 'imip' => 'mailto:p@example.com' },
                                      'scheduleStatus' => '5.1' } }
      }
      Icalendar::JSCalendar.event_from_jscalendar js, report: report
      lost = report.lost.map(&:property)
      expect(lost).to include 'recurrenceRules rscale', 'recurrenceRules skip'
      expect(lost.any? { |p| p.include? 'scheduleStatus' }).to be true
    end

    it 'preserves rich recurrence overrides instead of dropping them' do
      js = {
        '@type' => 'Event', 'uid' => 'js-3', 'start' => '2026-10-04T09:00:00',
        'recurrenceRules' => [{ 'frequency' => 'daily', 'count' => 3 }],
        'recurrenceOverrides' => { '2026-10-05T09:00:00' => { 'title' => 'Moved', 'start' => '2026-10-05T10:00:00' } }
      }
      event = Icalendar::JSCalendar.event_from_jscalendar js, report: report
      expect(report.preserved.map(&:property)).to include 'recurrenceOverrides/2026-10-05T09:00:00'
      exported = Icalendar::JSCalendar.event_to_jscalendar event
      expect(exported['recurrenceOverrides']).to eq js['recurrenceOverrides']
    end
  end
end
