use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use ByWater::MeetingBackgrounds qw(slugify squish uc_safe xml_escape fill_template
                                   fingerprint needs_render discover_templates within_size_limit);

is slugify('Kyle Hall'),            'Kyle-Hall',            'simple slug';
is slugify('Brendan A. Gallagher'), 'Brendan-A-Gallagher',  'periods + spaces';
is slugify('  Joy   Nelson  '),     'Joy-Nelson',           'collapses whitespace';
is slugify("O'Brien-Smith"),        'O-Brien-Smith',        'apostrophe + hyphen';

is squish("  a   b  c  "), 'a b c', 'squish collapses + trims';
is uc_safe('Lord of the Code'), 'LORD OF THE CODE', 'uppercase';

is xml_escape('Dev & Ops'),   'Dev &amp; Ops',          'escapes ampersand';
is xml_escape('a < b > "c"'), 'a &lt; b &gt; &quot;c&quot;', 'escapes <>"';

my $svg = '<text>{{NAME}}</text><text>{{TITLE_UPPER}}</text>'
    . '<image href="{{LOGO}}"/><image href="{{LOGO_WHITE}}"/><image href="{{LOGO_BLACK}}"/>{{NOPE}}';
my $out = fill_template($svg, {
    NAME => 'Kyle Hall', TITLE_UPPER => 'LORD OF THE CODE',
    LOGO => 'data:image/png;base64,X',
    LOGO_WHITE => 'data:image/png;base64,W', LOGO_BLACK => 'data:image/png;base64,B',
});
like $out, qr{<text>Kyle Hall</text>},        'NAME filled';
like $out, qr{<text>LORD OF THE CODE</text>}, 'TITLE_UPPER filled';
like $out, qr{href="data:image/png;base64,X"}, 'LOGO filled';
like $out, qr{href="data:image/png;base64,W"}, 'LOGO_WHITE filled';
like $out, qr{href="data:image/png;base64,B"}, 'LOGO_BLACK filled';
like $out, qr{\{\{NOPE\}\}},                   'unknown placeholder left intact';

# ---- fingerprint: stable, sensitive, unicode-safe ------------------------
my $svg_a = '<svg><text>Kyle Hall</text><text>LORD OF THE CODE</text></svg>';
my $svg_b = '<svg><text>Kyle Hall</text><text>DIRECTOR OF DEV</text></svg>';
like fingerprint($svg_a), qr/^[0-9a-f]{40}$/, 'fingerprint is a 40-char sha1 hex';
is   fingerprint($svg_a), fingerprint($svg_a), 'same input => same fingerprint';
isnt fingerprint($svg_a), fingerprint($svg_b), 'title change => different fingerprint';
ok   fingerprint("<svg><text>Rocío Dressler</text></svg>"),
     'unicode content fingerprints without dying';

# ---- needs_render truth table --------------------------------------------
ok   needs_render(1, 1, 'a', 'a'), 'force re-renders even when unchanged';
ok   needs_render(0, 0, 'a', 'a'), 'missing PNG re-renders';
ok   needs_render(0, 1, undef, 'a'), 'no stored fingerprint re-renders';
ok   needs_render(0, 1, 'a', 'b'), 'changed fingerprint re-renders';
ok ! needs_render(0, 1, 'a', 'a'), 'unchanged + present => skip';

# ---- discover_templates excludes _-prefixed scaffolds --------------------
my @tpls = map { (my $n = $_) =~ s{.*/}{}; $n =~ s/\.svg$//; $n }
           discover_templates("$RealBin/../templates");
ok  scalar( grep { $_ eq 'waves' }    @tpls ), 'waves template discovered';
ok  scalar( grep { $_ eq 'minimal' }  @tpls ), 'minimal template discovered';
ok !scalar( grep { $_ eq '_starter' } @tpls ), '_starter scaffold excluded';

# ---- within_size_limit (5 MB file cap) -----------------------------------
ok  within_size_limit(100,        5_000_000), 'small file within limit';
ok  within_size_limit(5_000_000,  5_000_000), 'exactly at limit is allowed';
ok !within_size_limit(5_000_001,  5_000_000), 'one byte over the limit fails';

done_testing;
