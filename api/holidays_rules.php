<?php
// UK public-holiday rules. Pure PHP, no database and no network: the calendar is computed from
// the rules that define it, so nobody has to extend a list every December and the seed and the
// importer can never disagree about a date.
//
// Shared by api/holidays.php (the endpoint) and seed_demo.php (the demo data).

/** The UK nations that keep different bank holidays. NULL region means "everyone in this workspace". */
const UK_REGIONS = [
    'england-and-wales' => 'England and Wales',
    'scotland'          => 'Scotland',
    'northern-ireland'  => 'Northern Ireland',
];

/**
 * Easter Sunday by the anonymous Gregorian algorithm.
 *
 * Computed rather than fetched: the alternative is a table somebody has to extend every year, or
 * a network call from a server that must work without one. Good Friday and Easter Monday hang off
 * this, and everything else in the UK calendar is a fixed date or an nth weekday.
 */
function easter_sunday($year) {
    $a = $year % 19;
    $b = intdiv($year, 100); $c = $year % 100;
    $d = intdiv($b, 4); $e = $b % 4;
    $f = intdiv($b + 8, 25);
    $g = intdiv($b - $f + 1, 3);
    $h = (19 * $a + $b - $d - $g + 15) % 30;
    $i = intdiv($c, 4); $k = $c % 4;
    $l = (32 + 2 * $e + 2 * $i - $h - $k) % 7;
    $m = intdiv($a + 11 * $h + 22 * $l, 451);
    $month = intdiv($h + $l - 7 * $m + 114, 31);
    $day = (($h + $l - 7 * $m + 114) % 31) + 1;
    return sprintf('%04d-%02d-%02d', $year, $month, $day);
}

function nth_weekday($year, $month, $weekday, $n) {
    $d = new DateTime(sprintf('%04d-%02d-01', $year, $month));
    while ($d->format('D') !== $weekday) $d->modify('+1 day');
    if ($n > 1) $d->modify('+' . (($n - 1) * 7) . ' days');
    return $d->format('Y-m-d');
}

function last_weekday($year, $month, $weekday) {
    $d = new DateTime(sprintf('%04d-%02d-01', $year, $month));
    $d->modify('last day of this month');
    while ($d->format('D') !== $weekday) $d->modify('-1 day');
    return $d->format('Y-m-d');
}

/** A fixed-date holiday falling at a weekend is kept on the next weekday ("substitute day"). */
function substitute_day($date, array $taken) {
    $d = new DateTime($date);
    while (in_array($d->format('D'), ['Sat', 'Sun'], true) || in_array($d->format('Y-m-d'), $taken, true)) $d->modify('+1 day');
    return $d->format('Y-m-d');
}

/**
 * The UK bank holidays for one year and nation, from the rules rather than a list.
 *
 * @return array [['day' => 'YYYY-MM-DD', 'label' => '...'], ...]
 */
function uk_bank_holidays($year, $region) {
    $easter = easter_sunday($year);
    $out = [];
    $taken = [];
    $add = function ($day, $label, $substitute = false) use (&$out, &$taken) {
        if ($substitute) $day = substitute_day($day, $taken);
        $out[] = ['day' => $day, 'label' => $label];
        $taken[] = $day;
    };

    $add(sprintf('%04d-01-01', $year), "New Year's Day", true);
    if ($region === 'scotland') $add(sprintf('%04d-01-02', $year), '2 January', true);
    if ($region === 'northern-ireland') $add(sprintf('%04d-03-17', $year), "St Patrick's Day", true);
    $add(date('Y-m-d', strtotime("$easter -2 days")), 'Good Friday');
    if ($region !== 'scotland') $add(date('Y-m-d', strtotime("$easter +1 day")), 'Easter Monday');
    $add(nth_weekday($year, 5, 'Mon', 1), 'Early May bank holiday');
    $add(last_weekday($year, 5, 'Mon'), 'Spring bank holiday');
    if ($region === 'northern-ireland') $add(sprintf('%04d-07-12', $year), 'Battle of the Boyne', true);
    $add($region === 'scotland' ? nth_weekday($year, 8, 'Mon', 1) : last_weekday($year, 8, 'Mon'), 'Summer bank holiday');
    if ($region === 'scotland') $add(sprintf('%04d-11-30', $year), "St Andrew's Day", true);
    $add(sprintf('%04d-12-25', $year), 'Christmas Day', true);
    $add(sprintf('%04d-12-26', $year), 'Boxing Day', true);

    usort($out, fn($a, $b) => strcmp($a['day'], $b['day']));
    return $out;
}
