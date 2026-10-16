import { mount } from '@vue/test-utils';
import { describe, expect, it } from 'vitest';
import TrackingIssuesBanner from '../components/people/TrackingIssuesBanner.vue';
import { issueCopy, parseTrackingIssues, TRACKING_ISSUES } from '../lib/tracking-issues';

describe('parseTrackingIssues', () => {
    it('keeps known codes in display order and drops everything else', () => {
        expect(parseTrackingIssues(['battery_optimization', 'nope', 7, 'location_services_off'])).toEqual([
            'location_services_off',
            'battery_optimization'
        ]);
        expect(parseTrackingIssues(undefined)).toEqual([]);
        expect(parseTrackingIssues('battery_optimization')).toEqual([]);
    });
});

describe('issueCopy', () => {
    it('speaks about someone else in the third person and about the viewer as "you"', () => {
        expect(issueCopy('battery_optimization', { name: 'Sam', self: false }).summary).toBe(
            "Sam should update their phone's Battery Optimization settings."
        );
        expect(issueCopy('battery_optimization', { name: 'Sam', self: true }).summary).toBe(
            "You should update your phone's Battery Optimization settings."
        );
    });

    it('has a title, a summary and steps for every code', () => {
        for (const issue of TRACKING_ISSUES) {
            const copy = issueCopy(issue, { name: 'Sam', self: false });
            expect(copy.title).not.toBe('');
            expect(copy.summary).not.toBe('');
            expect(copy.steps.length).toBeGreaterThan(0);
        }
    });
});

describe('TrackingIssuesBanner', () => {
    it('renders nothing when the phone reports no problems', () => {
        const wrapper = mount(TrackingIssuesBanner, { props: { issues: [], name: 'Sam', self: false } });
        expect(wrapper.find('[data-testid="tracking-issues"]').exists()).toBe(false);
    });

    it('names a single problem and reveals the fix steps on request', async () => {
        const wrapper = mount(TrackingIssuesBanner, {
            props: { issues: ['battery_optimization'], name: 'Sam', self: false }
        });
        expect(wrapper.text()).toContain('Battery settings are delaying updates');
        expect(wrapper.text()).toContain("Sam should update their phone's Battery Optimization settings.");
        expect(wrapper.find('ol').exists()).toBe(false);

        const toggle = wrapper.get('button');
        expect(toggle.text()).toBe('Learn how to fix this');
        await toggle.trigger('click');
        expect(toggle.attributes('aria-expanded')).toBe('true');
        expect(wrapper.findAll('ol li').length).toBeGreaterThan(0);
    });

    it('lists every problem under one headline when there are several', () => {
        const wrapper = mount(TrackingIssuesBanner, {
            props: { issues: ['location_services_off', 'battery_optimization'], name: 'Sam', self: false }
        });
        expect(wrapper.get('h3').text()).toBe('Location updates are being blocked');
        expect(wrapper.findAll('ul li')).toHaveLength(2);
    });
});
