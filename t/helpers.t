use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use ByWater::MeetingBackgrounds qw(wrap_words wrap_title_text split_layers);
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

# ---- fill_template {{KEY+N}} arithmetic -----------------------------------
is fill_template('h="{{EXTRA+118}}" t="-{{EXTRA}}"', { EXTRA => 76 }), 'h="194" t="-76"',
    '{{KEY+N}} adds N to the value';
is fill_template('{{EXTRA+118}}', { EXTRA => 0 }), '118', '{{KEY+N}} with a zero value is just N';
is fill_template('{{NOPE+3}}', {}), '{{NOPE+3}}', 'unknown {{KEY+N}} left intact';

# ---- wrap_words (titles wrap at 20 characters, never mid-word) -------------
is_deeply [ wrap_words('Head of Sales', 20) ], ['Head of Sales'], 'short title stays on one line';
is_deeply [ wrap_words('Pipeline Coordinator', 20) ], ['Pipeline Coordinator'],
    'exactly 20 characters stays on one line';
is_deeply [ wrap_words('Linux Administrator I', 20) ], [ 'Linux Administrator', 'I' ],
    '21 characters wraps';
is_deeply [ wrap_words('Vice President of Strategic Partnerships', 20) ],
    [ 'Vice President of', 'Strategic', 'Partnerships' ], 'long title wraps to three lines';
is_deeply [ wrap_words('Director of Development & Operations', 20) ],
    [ 'Director of', 'Development &', 'Operations' ], 'ampersand counts as one character';
is_deeply [ wrap_words('Supercalifragilisticexpialidocious Lead', 20) ],
    [ 'Supercalifragilisticexpialidocious', 'Lead' ], 'an over-long word is not broken';
is_deeply [ wrap_words('', 20) ], [''], 'empty title is one empty line';

# ---- wrap_title_text -------------------------------------------------------
my $title_svg = '<text x="96" y="124">{{NAME}}</text>'
              . '<text x="98" y="172" font-size="30" rx="4">{{TITLE_UPPER}}</text>';
my ( $one_line, $no_extra ) = wrap_title_text( $title_svg, { TITLE_UPPER => ['HEAD OF SALES'] } );
is $one_line, $title_svg, 'one-line title leaves the template untouched';
is $no_extra, 0,          'one-line title adds no height';
my ( $wrapped, $extra ) = wrap_title_text( $title_svg, { TITLE_UPPER => [ 'A B', 'C &amp; D', 'E' ] } );
like $wrapped, qr{font-size="30" rx="4">A B<tspan x="98" dy="38">C &amp; D</tspan><tspan x="98" dy="38">E</tspan></text>},
    'further lines become tspans at the text x, 1.25 x font-size apart';
like $wrapped, qr{<text x="96" y="124">\{\{NAME\}\}</text>}, 'other placeholders are not wrapped';
is $extra, 76, 'two extra lines add two line heights';

# ---- split_layers ----------------------------------------------------------
my $layered = <<'SVG';
<svg width="10" height="10" xmlns="http://www.w3.org/2000/svg">
  <!-- placeholders: {{NAME}} <rect> -->
  <defs><linearGradient id="base"/></defs>
  <rect width="10" height="10" fill="url(#base)"/>
  <image href="data:image/jpeg;base64,AAAA"/>
  <g>
    <!-- not a placeholder: {{NAME}} -->
    <path d="M0,0"/>
  </g>
  <g font-family="x">
    <rect height="{{TITLE_EXTRA_HEIGHT+118}}"/>
    <g><text>{{NAME}}</text></g>
  </g>
  <image href="{{LOGO}}"/>
</svg>
SVG
my ( $background, $foreground ) = split_layers($layered);
like   $background, qr{\A<svg width="10"[^>]*>.*</svg>\n\z}s, 'background keeps the svg root';
like   $background, qr{<defs>},              'defs copied to background';
like   $foreground, qr{<defs>},              'defs copied to foreground';
like   $background, qr{fill="url\(#base\)"}, 'fill is background';
like   $background, qr{base64,AAAA},         'photo is background';
like   $background, qr{<path d="M0,0"/>},    'group with only a commented placeholder is background';
unlike $background, qr{font-family|LOGO},    'no text or logo in background';
like   $foreground, qr{<g font-family="x">.*<g><text>\{\{NAME\}\}</text></g>\s*</g>}s,
    'nested text group is foreground, whole';
like   $foreground, qr{href="\{\{LOGO\}\}"}, 'logo is foreground';
unlike $foreground, qr{base64,AAAA|M0,0|#base\)"/>}, 'no artwork in foreground';
is scalar( () = split_layers('<svg><defs/><g><text>{{NAME}}</text></g></svg>') ), 0,
    'foreground-only template is not split';
is scalar( () = split_layers('<svg><rect/></svg>') ), 0, 'background-only template is not split';

done_testing;
