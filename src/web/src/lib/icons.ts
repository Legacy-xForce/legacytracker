// Material Symbols (rounded), the closest web match to the Material icons the phone app uses.
// "-fill" files are the filled style Flutter's `Icons.*_rounded` draws; the plain files are the
// outlined style of its `*_outlined` icons.
import add from '@material-symbols/svg-400/rounded/add.svg?raw';
import arrowBack from '@material-symbols/svg-400/rounded/arrow_back.svg?raw';
import battery1 from '@material-symbols/svg-400/rounded/battery_1_bar-fill.svg?raw';
import battery2 from '@material-symbols/svg-400/rounded/battery_2_bar-fill.svg?raw';
import battery3 from '@material-symbols/svg-400/rounded/battery_3_bar-fill.svg?raw';
import battery4 from '@material-symbols/svg-400/rounded/battery_4_bar-fill.svg?raw';
import battery5 from '@material-symbols/svg-400/rounded/battery_5_bar-fill.svg?raw';
import batteryAlert from '@material-symbols/svg-400/rounded/battery_alert-fill.svg?raw';
import batteryCharging from '@material-symbols/svg-400/rounded/battery_charging_full-fill.svg?raw';
import batteryFull from '@material-symbols/svg-400/rounded/battery_full-fill.svg?raw';
import bolt from '@material-symbols/svg-400/rounded/bolt-fill.svg?raw';
import calendarMonth from '@material-symbols/svg-400/rounded/calendar_month-fill.svg?raw';
import check from '@material-symbols/svg-400/rounded/check.svg?raw';
import chevronLeft from '@material-symbols/svg-400/rounded/chevron_left.svg?raw';
import chevronRight from '@material-symbols/svg-400/rounded/chevron_right.svg?raw';
import close from '@material-symbols/svg-400/rounded/close.svg?raw';
import dateRange from '@material-symbols/svg-400/rounded/date_range.svg?raw';
import cloudOff from '@material-symbols/svg-400/rounded/cloud_off-fill.svg?raw';
import directions from '@material-symbols/svg-400/rounded/directions-fill.svg?raw';
import directionsCar from '@material-symbols/svg-400/rounded/directions_car-fill.svg?raw';
import error from '@material-symbols/svg-400/rounded/error.svg?raw';
import event from '@material-symbols/svg-400/rounded/event-fill.svg?raw';
import eventBusy from '@material-symbols/svg-400/rounded/event_busy.svg?raw';
import fitAll from '@material-symbols/svg-400/rounded/zoom_out_map.svg?raw';
import group from '@material-symbols/svg-400/rounded/group-fill.svg?raw';
import history from '@material-symbols/svg-400/rounded/history.svg?raw';
import info from '@material-symbols/svg-400/rounded/info.svg?raw';
import key from '@material-symbols/svg-400/rounded/key-fill.svg?raw';
import landscape from '@material-symbols/svg-400/rounded/landscape.svg?raw';
import layers from '@material-symbols/svg-400/rounded/layers.svg?raw';
import location from '@material-symbols/svg-400/rounded/location_on.svg?raw';
import locationOff from '@material-symbols/svg-400/rounded/location_off.svg?raw';
import lock from '@material-symbols/svg-400/rounded/lock.svg?raw';
import logout from '@material-symbols/svg-400/rounded/logout.svg?raw';
import locationSearching from '@material-symbols/svg-400/rounded/location_searching.svg?raw';
import map from '@material-symbols/svg-400/rounded/map.svg?raw';
import myLocation from '@material-symbols/svg-400/rounded/my_location-fill.svg?raw';
import nearMe from '@material-symbols/svg-400/rounded/near_me-fill.svg?raw';
import openInNew from '@material-symbols/svg-400/rounded/open_in_new.svg?raw';
import palette from '@material-symbols/svg-400/rounded/palette.svg?raw';
import pause from '@material-symbols/svg-400/rounded/pause-fill.svg?raw';
import person from '@material-symbols/svg-400/rounded/person.svg?raw';
import place from '@material-symbols/svg-400/rounded/location_on-fill.svg?raw';
import playArrow from '@material-symbols/svg-400/rounded/play_arrow-fill.svg?raw';
import refresh from '@material-symbols/svg-400/rounded/refresh.svg?raw';
import remove from '@material-symbols/svg-400/rounded/remove.svg?raw';
import route from '@material-symbols/svg-400/rounded/route.svg?raw';
import satellite from '@material-symbols/svg-400/rounded/satellite_alt.svg?raw';
import shareLocation from '@material-symbols/svg-400/rounded/share_location.svg?raw';
import shield from '@material-symbols/svg-400/rounded/shield.svg?raw';
import speed from '@material-symbols/svg-400/rounded/speed-fill.svg?raw';
import speedOutlined from '@material-symbols/svg-400/rounded/speed.svg?raw';
import straighten from '@material-symbols/svg-400/rounded/straighten-fill.svg?raw';
import timelapse from '@material-symbols/svg-400/rounded/timelapse-fill.svg?raw';
import trash from '@material-symbols/svg-400/rounded/delete.svg?raw';
import timer from '@material-symbols/svg-400/rounded/timer.svg?raw';
import touchApp from '@material-symbols/svg-400/rounded/touch_app.svg?raw';
import trophy from '@material-symbols/svg-400/rounded/trophy-fill.svg?raw';
import trendingUp from '@material-symbols/svg-400/rounded/trending_up.svg?raw';
import visibility from '@material-symbols/svg-400/rounded/visibility.svg?raw';
import visibilityOff from '@material-symbols/svg-400/rounded/visibility_off.svg?raw';

const raw = {
    add,
    arrowBack,
    battery1,
    battery2,
    battery3,
    battery4,
    battery5,
    batteryAlert,
    batteryCharging,
    batteryFull,
    bolt,
    calendarMonth,
    check,
    chevronLeft,
    chevronRight,
    close,
    cloudOff,
    dateRange,
    directions,
    directionsCar,
    error,
    event,
    eventBusy,
    fitAll,
    group,
    history,
    info,
    key,
    landscape,
    layers,
    location,
    locationOff,
    locationSearching,
    lock,
    logout,
    map,
    myLocation,
    nearMe,
    openInNew,
    palette,
    pause,
    person,
    place,
    playArrow,
    refresh,
    remove,
    route,
    satellite,
    shareLocation,
    shield,
    speed,
    speedOutlined,
    straighten,
    timelapse,
    timer,
    trash,
    touchApp,
    trophy,
    trendingUp,
    visibility,
    visibilityOff
};

export type IconName = keyof typeof raw;

// The files are fixed 48px black squares; make them follow the surrounding font size and colour.
export const icons = Object.fromEntries(
    Object.entries(raw).map(([name, svg]) => [
        name,
        svg.replace('width="48" height="48"', 'width="1em" height="1em" fill="currentColor" aria-hidden="true"')
    ])
) as Record<IconName, string>;

/** The battery glyph for a charge level, as the app picks it. */
export function batteryIcon(level: number | null, charging: boolean): IconName {
    if (charging) return 'batteryCharging';
    if (level === null) return 'batteryFull';
    if (level >= 90) return 'batteryFull';
    if (level >= 70) return 'battery5';
    if (level >= 55) return 'battery4';
    if (level >= 40) return 'battery3';
    if (level >= 25) return 'battery2';
    if (level >= 10) return 'battery1';
    return 'batteryAlert';
}
