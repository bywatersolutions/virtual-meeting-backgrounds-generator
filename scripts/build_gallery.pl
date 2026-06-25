#!/usr/bin/env perl
#
# build_gallery.pl — generate the GitHub Pages gallery from staff/manifest.json.
#
# Writes a static site into a target directory (default ./_site):
#   index.html              a light landing page: just a filterable list of names
#   people/<slug>.html      one page per person with their backgrounds + downloads
#
# The Pages workflow drops the staff/ images into the same site dir and deploys it.
#
# Usage:   perl -Ilib scripts/build_gallery.pl [SITE_DIR]
# Env:     MANIFEST  path to the manifest (default: <repo>/staff/manifest.json)
#
use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Spec;
use File::Path qw(make_path);
use JSON::PP;
use Encode ();
use ByWater::MeetingBackgrounds qw(xml_escape);

my $ROOT     = File::Spec->rel2abs("$RealBin/..");
my $SITE     = shift(@ARGV) // '_site';
my $manifest = $ENV{MANIFEST} // "$ROOT/staff/manifest.json";

open( my $fh, '<:raw', $manifest ) or die "read $manifest: $!\n";
local $/;
my $bytes = <$fh>;
close $fh;
my $data = JSON::PP->new->utf8->decode($bytes);
die "manifest is not a list\n" unless ref $data eq 'ARRAY';

my @people = sort { lc( $a->{name} ) cmp lc( $b->{name} ) } @$data;
my $tpl_count = ( @people && ref $people[0]{renders} eq 'HASH' )
    ? scalar keys %{ $people[0]{renders} } : 0;
my $count = scalar @people;

# Percent-encode a relative path for href/src (keeps '/'), so accented slugs
# resolve to their UTF-8-named files.
sub url_path {
    my $s = Encode::encode_utf8( shift // '' );
    $s =~ s{([^A-Za-z0-9\-._~/])}{ sprintf '%%%02X', ord $1 }ge;
    return $s;
}

# Shared <head> + styles for both page types. $depth is how many levels below the
# site root the page sits (0 = index, 1 = people/<slug>).
sub head {
    my ( $title, $depth ) = @_;
    return <<"HEAD";
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>$title</title>
<style>
  :root { --bg:#0b1f33; --card:#11283f; --ink:#eef4fb; --muted:#9db6cf; --accent:#4E8AC2; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--ink);
         font-family:'Helvetica Neue',Arial,sans-serif; line-height:1.45; }
  a { color:var(--accent); }
  header { padding:32px 24px 12px; max-width:1100px; margin:0 auto; }
  h1 { margin:0 0 6px; font-size:30px; }
  header p { margin:0 0 16px; color:var(--muted); }
  .back { display:inline-block; margin-bottom:10px; text-decoration:none; font-weight:600; }
  #q { width:100%; max-width:420px; padding:10px 14px; border-radius:8px;
       border:1px solid #27425f; background:#0e2336; color:var(--ink); font-size:16px; }
  main { max-width:1100px; margin:0 auto; padding:8px 24px 64px; }
  ul.people { list-style:none; padding:0; margin:0; max-width:620px; }
  ul.people a { display:flex; justify-content:space-between; gap:16px; align-items:baseline;
                padding:12px 14px; border-radius:8px; text-decoration:none; color:var(--ink);
                border:1px solid transparent; }
  ul.people a:hover { background:var(--card); border-color:#1d3a55; }
  ul.people .title { color:var(--muted); font-size:13px; text-transform:uppercase; letter-spacing:1px; }
  .title { color:var(--muted); }
  .note { color:var(--muted); font-size:13px; margin:6px 0 0; }
  .grid { display:grid; gap:16px; grid-template-columns:repeat(auto-fill,minmax(260px,1fr)); }
  figure { margin:0; }
  figure img { width:100%; aspect-ratio:16/9; object-fit:cover; border-radius:8px;
               display:block; background:#0e2336; }
  /* Transparent foreground overlays: show a checkerboard so the transparency is
     obvious and both the white-ink and dark-ink variants stay readable. */
  figure img.transparent {
    background:
      linear-gradient(45deg,#9098a2 25%,transparent 25%,transparent 75%,#9098a2 75%),
      linear-gradient(45deg,#9098a2 25%,#b6bcc4 25%,#b6bcc4 75%,#9098a2 75%);
    background-size:28px 28px; background-position:0 0,14px 14px; }
  figcaption { display:flex; justify-content:space-between; align-items:center;
               margin-top:6px; font-size:13px; color:var(--muted); }
  .dl { color:var(--accent); text-decoration:none; font-weight:600; }
  .dl:hover { text-decoration:underline; }
  .empty { color:var(--muted); padding:24px 0; }
  footer { max-width:1100px; margin:0 auto; padding:0 24px 48px; color:var(--muted); font-size:13px; }
</style>
</head>
HEAD
}

# ---- landing page: filterable list of names ------------------------------
make_path("$SITE/people");
open( my $idx, '>:encoding(UTF-8)', "$SITE/index.html" ) or die "write index: $!\n";
print {$idx} head( 'ByWater Virtual Meeting Backgrounds', 0 );
print {$idx} <<"HDR";
<body>
<header>
  <h1>ByWater Virtual Meeting Backgrounds</h1>
  <p>Find your name, open your page, and download a background to use in Zoom, Teams, Google Meet, etc. Backgrounds are 1920&times;1080 (16:9); the <strong>-original</strong> ones are 1440&times;1080 (4:3) for Zoom&rsquo;s &ldquo;Original Ratio&rdquo; setting.</p>
  <input id="q" type="search" placeholder="Filter by name…" autocomplete="off" aria-label="Filter by name">
</header>
<main>
  <ul class="people" id="people">
HDR

for my $p (@people) {
    my $name = xml_escape( $p->{name} );
    my $title = xml_escape( $p->{title} // '' );
    ( my $key = lc( $p->{name} ) ) =~ s/\s+/ /g;
    my $dataname = xml_escape($key);
    my $href = url_path("people/$p->{slug}.html");
    print {$idx} qq{    <li class="person" data-name="$dataname"><a href="$href"><span>$name</span><span class="title">$title</span></a></li>\n};
}

print {$idx} <<"FTR";
  </ul>
  <p id="noresults" class="empty" hidden>No one matches that name.</p>
</main>
<footer>$count people &middot; $tpl_count backgrounds each &middot; generated from the ByWater team page.</footer>
<script>
  var q = document.getElementById('q');
  var rows = Array.prototype.slice.call(document.querySelectorAll('.person'));
  var none = document.getElementById('noresults');
  q.addEventListener('input', function () {
    var term = q.value.trim().toLowerCase(), shown = 0;
    rows.forEach(function (r) {
      var m = r.dataset.name.indexOf(term) !== -1;
      r.hidden = !m; if (m) shown++;
    });
    none.hidden = shown !== 0;
  });
</script>
</body>
</html>
FTR
close $idx;

# ---- one page per person -------------------------------------------------
for my $p (@people) {
    my $name  = xml_escape( $p->{name} );
    my $title = xml_escape( $p->{title} // '' );
    open( my $pg, '>:encoding(UTF-8)', "$SITE/people/$p->{slug}.html" )
        or die "write people/$p->{slug}.html: $!\n";
    print {$pg} head( "$name — ByWater Backgrounds", 1 );
    print {$pg} qq{<body>\n<header>\n};
    print {$pg} qq{  <p><a class="back" href="../index.html">&larr; All names</a></p>\n};
    print {$pg} qq{  <h1>$name</h1>\n};
    print {$pg} qq{  <p class="title">$title</p>\n} if length $title;
    print {$pg} qq{  <p class="note">Files marked <strong>-original</strong> are 4:3 (for Zoom&rsquo;s &ldquo;Original Ratio&rdquo;); the rest are 16:9.</p>\n};
    print {$pg} qq{</header>\n<main>\n  <div class="grid">\n};
    for my $tpl ( sort keys %{ $p->{renders} || {} } ) {
        my $href  = url_path("../staff/$p->{slug}/$tpl.png");
        my $label = xml_escape($tpl);
        # Foreground overlays are transparent PNGs — flag them so the CSS shows a
        # checkerboard behind them instead of the solid dark card background.
        my $img_class = $tpl =~ /^foreground/ ? ' class="transparent"' : '';
        print {$pg} qq{    <figure>\n};
        print {$pg} qq{      <a href="$href" target="_blank" rel="noopener"><img$img_class loading="lazy" src="$href" alt="$label background for $name"></a>\n};
        print {$pg} qq{      <figcaption><span>$label</span><a class="dl" href="$href" download>Download</a></figcaption>\n};
        print {$pg} qq{    </figure>\n};
    }
    print {$pg} qq{  </div>\n</main>\n</body>\n</html>\n};
    close $pg;
}

print "wrote $SITE/index.html + $count person pages\n";
