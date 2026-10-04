# frozen_string_literal: true

require 'spec_helper'

describe Icalendar::Jscalendar do
  let(:adapter_class) { described_class::Adapter }

  def convert(events)
    adapter_class.new.events_to_object(events)
  end

  def parse(object)
    adapter_class.new.object_to_events(object)
  end

  describe 'single event conversion' do
    it 'preserves a floating local event, participants, and reminders' do
      event = Icalendar::Event.new
      event.uid = 'floating-event'
      event.dtstart = Icalendar::Values::DateTime.new('20260210T083000')
      event.duration = 'PT45M'
      event.summary = 'Floating sync'
      event.append_attendee Icalendar::Values::CalAddress.new('mailto:guest@example.com',
                                                              'cn' => 'Guest',
                                                              'partstat' => 'TENTATIVE',
                                                              'rsvp' => 'TRUE')
      alarm = event.alarm
      alarm.uid = 'reminder-1'
      alarm.trigger = '-PT10M'
      alarm.description = 'Get ready'
      event.x_vendor_note = 'kept'

      conversion = convert([event])
      object = conversion.object.fetch('floating-event')

      expect(object['start']).to eq('2026-02-10T08:30:00')
      expect(object['showWithoutTime']).to eq(true)
      expect(object['allDay']).to eq(false)
      expect(object).not_to have_key('timeZone')
      expect(object['duration']).to eq('PT45M')
      participant = object['participants'].values.first
      expect(participant['sendTo']).to eq('imip' => 'guest@example.com')
      expect(participant['name']).to eq('Guest')
      expect(participant['participationStatus']).to eq('tentative')
      expect(participant['expectReply']).to eq(true)
      expect(object['alerts'].keys).to eq(['reminder-1'])
      expect(object['alerts']['reminder-1']['trigger']).to eq(
        '@type' => 'OffsetTrigger',
        'offset' => '-PT10M',
        'relativeTo' => 'start'
      )
      expect(object['alerts']['reminder-1']['x-icalendar-alarm'])
        .to include('description' => 'Get ready')
      extension = object['x-icalendar-data']['properties'].find do |property|
        property['name'] == 'x_vendor_note'
      end
      expect(extension['values'].first['value']).to eq('kept')

      back = parse(conversion.object)
      restored = back.object.first

      expect(restored.dtstart.value_ical).to eq('20260210T083000')
      expect(restored.dtstart.ical_params).to be_empty
      expect(restored.duration.value_ical).to eq('PT45M')
      expect(restored.attendee.first.to_ical(Icalendar::Event.default_property_types['attendee']))
        .to include(':mailto:guest@example.com')
      expect(restored.alarms.first.uid).to eq('reminder-1')
      expect(restored.alarms.first.trigger.value_ical).to eq('-PT10M')
      expect(restored.alarms.first.description).to eq('Get ready')
      expect(restored.custom_property('x_vendor_note').first).to eq('kept')
      expect(conversion.losses.map { |loss| loss['path'] })
        .to include(a_string_including('/x_vendor_note'))
    end

    it 'converts an all-day event to a date and exclusive duration' do
      event = Icalendar::Event.new
      event.uid = 'all-day-event'
      event.dtstart = Icalendar::Values::Date.new('20260307')
      event.dtend = Icalendar::Values::Date.new('20260308')
      event.summary = 'Holiday'

      conversion = convert([event])
      object = conversion.object.fetch('all-day-event')

      expect(object['allDay']).to eq(true)
      expect(object['showWithoutTime']).to eq(true)
      expect(object['start']).to eq('2026-03-07')
      expect(object['duration']).to eq('P1D')
      expect(object).not_to have_key('timeZone')

      restored = parse(conversion.object).object.first
      expect(restored.dtstart).to be_a(Icalendar::Values::Date)
      expect(restored.dtstart.value_ical).to eq('20260307')
      expect(restored.dtend.value_ical).to eq('20260308')
    end

    it 'keeps the event and alarm IDs stable in JSON output' do
      event = Icalendar::Event.new
      event.uid = 'json-id'
      event.dtstart = Icalendar::Values::Date.new('20260601')
      event.dtend = Icalendar::Values::Date.new('20260602')
      alarm = event.alarm
      alarm.uid = 'alarm-id'
      alarm.trigger = 'PT0S'
      alarm.description = 'Now'

      generated = described_class.generate([event])
      expect(generated.object).to include('"json-id"')
      expect(generated.object).to include('"alarm-id"')
      expect(described_class.parse(generated.object).object.first.uid).to eq('json-id')
    end
  end

  describe 'recurring events with exceptions' do
    it 'uses fixed local timezone data for the series and one exception' do
      master = Icalendar::Event.new
      master.uid = 'weekly-series'
      master.dtstart = Icalendar::Values::DateTime.new('20260105T090000', 'tzid' => 'Asia/Shanghai')
      master.duration = 'PT1H'
      master.summary = 'Weekly review'
      master.append_rrule 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;WKST=MO'

      exception = Icalendar::Event.new
      exception.uid = 'weekly-series'
      exception.dtstart = Icalendar::Values::DateTime.new('20260119T100000', 'tzid' => 'Asia/Shanghai')
      exception.duration = 'PT90M'
      exception.recurrence_id = Icalendar::Values::DateTime.new('20260119T090000', 'tzid' => 'Asia/Shanghai')
      exception.summary = 'Rescheduled review'
      exception.append_rrule 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;WKST=MO'

      conversion = convert([master, exception])
      object = conversion.object.fetch('weekly-series')

      expect(object['recurrenceRules']).to eq([
        '@type' => 'RecurrenceRule',
        'frequency' => 'weekly',
        'interval' => 2,
        'firstDayOfWeek' => 1,
        'byDay' => ['monday']
      ])
      override = object['recurrenceOverrides'].fetch('2026-01-19T09:00:00')
      expect(override['title']).to eq('Rescheduled review')
      expect(override['start']).to eq('2026-01-19T10:00:00')
      expect(override['timeZone']).to eq('Asia/Shanghai')
      expect(override['duration']).to eq('PT90M')

      back = parse(conversion.object)
      restored_master, restored_exception = back.object

      expect(back.object.map(&:uid)).to eq(%w[weekly-series weekly-series])
      expect(restored_master.rrule.first.value_ical).to eq('FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;WKST=MO')
      expect(restored_master.dtstart.ical_params['tzid']).to eq(['Asia/Shanghai'])
      expect(restored_exception.recurrence_id.value_ical).to eq('20260119T090000')
      expect(restored_exception.recurrence_id.ical_params['tzid']).to eq(['Asia/Shanghai'])
      expect(restored_exception.dtstart.value_ical).to eq('20260119T100000')
      expect(restored_exception.duration.value_ical).to eq('PT90M')
      expect(restored_exception.summary).to eq('Rescheduled review')
    end

    it 'represents a single excluded occurrence without silently dropping EXDATE' do
      event = Icalendar::Event.new
      event.uid = 'excluded-day'
      event.dtstart = Icalendar::Values::Date.new('20260401')
      event.dtend = Icalendar::Values::Date.new('20260402')
      event.append_rrule 'FREQ=WEEKLY'
      event.append_exdate Icalendar::Values::Date.new('20260408')

      conversion = convert([event])
      object = conversion.object.fetch('excluded-day')
      expect(object['recurrenceOverrides']['2026-04-08']).to eq('excluded' => true)

      restored = parse(conversion.object).object.first
      expect(restored.exdate.first).to be_a(Icalendar::Values::Date)
      expect(restored.exdate.first.value_ical).to eq('20260408')
    end
  end

  describe 'loss reporting' do
    it 'retains unsupported iCalendar properties and reports each extension' do
      event = Icalendar::Event.new
      event.uid = 'extended-event'
      event.dtstart = Icalendar::Values::Date.new('20260501')
      event.dtend = Icalendar::Values::Date.new('20260502')
      event.append_custom_property 'x_event_color', 'ultraviolet'

      conversion = convert([event])
      paths = conversion.losses.map { |loss| loss['path'] }

      expect(paths).to include(a_string_including('/x_event_color'))
      extension = conversion.object.fetch('extended-event')['x-icalendar-data']['properties']
        .find { |property| property['name'] == 'x_event_color' }
      expect(extension['values'].first['value']).to eq('ultraviolet')

      restored = parse(conversion.object).object.first
      expect(restored.custom_property('x_event_color').first).to eq('ultraviolet')
    end
  end
end
