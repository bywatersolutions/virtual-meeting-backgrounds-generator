#!/usr/bin/env perl
#
# build_gallery.pl — generate the GitHub Pages gallery (index.html) from
# staff/manifest.json. Prints the HTML to stdout; the Pages workflow assembles a
# _site/ from this plus the staff/ images and deploys it.
#
# Each person gets a card (name + title) with a thumbnail and download link for
# every template. Images are lazy-loaded and there's a client-side name filter,
# so an employee can find themselves without the page pulling every image.
#
# Environment:
#   MANIFEST   path to the manifest (default: <repo>/staff/manifest.json)
#
use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Spec;
use JSON::PP;
use Encode ();
use ByWater::MeetingBackgrounds qw(xml_escape);

binmode STDOUT, ':encoding(UTF-8)';

my $ROOT     = File::Spec->rel2abs("$RealBin/..");
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

# Percent-encode a relative path for use in href/src (keeps '/'), so accented
# slugs resolve to their UTF-8-named files on disk.
sub url_path {
    my $s = Encode::encode_utf8( shift // '' );
    $s =~ s{([^A-Za-z0-9\-._~/])}{ sprintf '%%%02X', ord $1 }ge;
    return $s;
}

my $count = scalar @people;

print <<"HEAD";
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>ByWater Virtual Meeting Backgrounds</title>
<style>
  :root { --bg:#0b1f33; --card:#11283f; --ink:#eef4fb; --muted:#9db6cf; --accent:#4E8AC2; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--ink);
         font-family:'Helvetica Neue',Arial,sans-serif; line-height:1.45; }
  header { padding:32px 24px 16px; max-width:1200px; margin:0 auto; }
  h1 { margin:0 0 6px; font-size:30px; }
  header p { margin:0 0 16px; color:var(--muted); }
  #q { width:100%; max-width:420px; padding:10px 14px; border-radius:8px;
       border:1px solid #27425f; background:#0e2336; color:var(--ink); font-size:16px; }
  main { max-width:1200px; margin:0 auto; padding:8px 24px 64px; }
  .person { background:var(--card); border:1px solid #1d3a55; border-radius:12px;
            padding:18px 20px; margin:18px 0; }
  .person h2 { margin:0; font-size:20px; }
  .person .title { margin:2px 0 14px; color:var(--muted); font-size:14px;
                   letter-spacing:1px; text-transform:uppercase; }
  .grid { display:grid; gap:16px; grid-template-columns:repeat(auto-fill,minmax(240px,1fr)); }
  figure { margin:0; }
  figure img { width:100%; aspect-ratio:16/9; object-fit:cover; border-radius:8px;
               display:block; background:#0e2336; }
  figcaption { display:flex; justify-content:space-between; align-items:center;
               margin-top:6px; font-size:13px; color:var(--muted); }
  .dl { color:var(--accent); text-decoration:none; font-weight:600; }
  .dl:hover { text-decoration:underline; }
  .empty { color:var(--muted); padding:24px 0; }
  footer { max-width:1200px; margin:0 auto; padding:0 24px 48px; color:var(--muted); font-size:13px; }
</style>
</head>
<body>
<header>
  <h1>ByWater Virtual Meeting Backgrounds</h1>
  <p>Find your name, download a background, and set it as your virtual background in Zoom, Teams, Google Meet, etc. Every image is 1920&times;1080.</p>
  <input id="q" type="search" placeholder="Filter by name…" autocomplete="off" aria-label="Filter by name">
</header>
<main id="people">
HEAD

for my $p (@people) {
    my $name  = xml_escape( $p->{name} );
    my $title = xml_escape( $p->{title} // '' );
    ( my $key = lc( $p->{name} ) ) =~ s/\s+/ /g;
    my $dataname = xml_escape($key);

    print qq{  <section class="person" data-name="$dataname">\n};
    print qq{    <h2>$name</h2>\n};
    print qq{    <p class="title">$title</p>\n} if length $title;
    print qq{    <div class="grid">\n};
    for my $tpl ( sort keys %{ $p->{renders} || {} } ) {
        my $href  = url_path("staff/$p->{slug}/$tpl.png");
        my $label = xml_escape($tpl);
        print qq{      <figure>\n};
        print qq{        <a href="$href" target="_blank" rel="noopener"><img loading="lazy" src="$href" alt="$label background for $name"></a>\n};
        print qq{        <figcaption><span>$label</span><a class="dl" href="$href" download>Download</a></figcaption>\n};
        print qq{      </figure>\n};
    }
    print qq{    </div>\n};
    print qq{  </section>\n};
}

print <<"FOOT";
  <p id="noresults" class="empty" hidden>No one matches that name.</p>
</main>
<footer>
  $count people &middot; $tpl_count templates each &middot; generated from the ByWater team page.
</footer>
<script>
  var q = document.getElementById('q');
  var people = Array.prototype.slice.call(document.querySelectorAll('.person'));
  var none = document.getElementById('noresults');
  q.addEventListener('input', function () {
    var term = q.value.trim().toLowerCase();
    var shown = 0;
    people.forEach(function (s) {
      var match = s.dataset.name.indexOf(term) !== -1;
      s.hidden = !match;
      if (match) shown++;
    });
    none.hidden = shown !== 0;
  });
</script>
</body>
</html>
FOOT
