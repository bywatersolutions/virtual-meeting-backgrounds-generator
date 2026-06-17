#!/usr/bin/env perl
#
# render.pl — stage 2: read the people YAML and render their backgrounds.
#
# Stage 1 (fetch.pl) produces the people YAML by scraping the team page; this
# stage is offline. It:
#   1. Reads people (name, title, slug) from the YAML file.
#   2. Prunes staff/<slug>/ directories for people no longer in the YAML.
#   3. For each person x template, renders staff/<slug>/<template>.png — but only
#      when something changed. The fingerprint of the filled SVG (template markup +
#      name + title + logo) is stored in the manifest; a background is re-rendered
#      only if that fingerprint changed, the PNG is missing, or FORCE=1 is set.
#
# Every background is rendered at 1920x1080 (16:9) — the size every major platform
# (Zoom, Teams, Google Meet, etc.) uses — and kept under a 5 MB file-size cap so it
# uploads everywhere (Zoom rejects backgrounds over 5 MB). Oversized PNGs are
# optimized with pngquant when available, and the run fails if one still won't fit.
# Rendering shells out to `rsvg-convert` (librsvg). See README "Why Perl + rsvg".
#
# Environment overrides:
#   PEOPLE_FILE  input YAML path (default: <repo>/data/people.yaml)
#   OUTPUT_DIR   output directory (default: <repo>/staff) — handy for previews
#   FORCE        truthy => re-render even if nothing changed
#   DRY_RUN      truthy => report the people; no prune, no render
#   WIDTH/HEIGHT output size (default 1920x1080)
#   MAX_BYTES    per-file size cap in bytes (default 5_000_000)
#
use strict;
use warnings;
use feature 'say';
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Spec;
use File::Basename qw(basename);
use File::Path qw(make_path remove_tree);
use Encode qw(decode_utf8);
use JSON::PP;
use ByWater::MeetingBackgrounds qw(read_people slugify uc_safe xml_escape
                                   fill_template build_logo_uri
                                   fingerprint needs_render discover_templates within_size_limit);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# ---- configuration -------------------------------------------------------
my $ROOT         = File::Spec->rel2abs("$RealBin/..");
my $TEMPLATE_DIR = "$ROOT/templates";
my $LOGO_PATH    = "$ROOT/assets/bywater_logo.png";
my $PEOPLE_FILE  = $ENV{PEOPLE_FILE} // "$ROOT/data/people.yaml";
my $OUTPUT_DIR   = $ENV{OUTPUT_DIR}  // "$ROOT/staff";
my $WIDTH        = $ENV{WIDTH}  // 1920;   # 16:9 — the size every major platform uses
my $HEIGHT       = $ENV{HEIGHT} // 1080;
my $MAX_BYTES    = $ENV{MAX_BYTES} // 5_000_000;   # per-file cap; Zoom rejects > 5 MB
my $FORCE        = $ENV{FORCE}   ? 1 : 0;
my $DRY_RUN      = $ENV{DRY_RUN} ? 1 : 0;

# ---- preflight -----------------------------------------------------------
die "People file not found: $PEOPLE_FILE (run fetch.pl first)\n" unless -f $PEOPLE_FILE;
die "Logo not found: $LOGO_PATH\n" unless -f $LOGO_PATH;
my @templates = discover_templates($TEMPLATE_DIR);
die "No templates found in $TEMPLATE_DIR\n" unless @templates;
unless ($DRY_RUN) {
    die "rsvg-convert not found on PATH (install librsvg2-bin)\n"
        unless `command -v rsvg-convert 2>/dev/null`;
}

# ---- 1. read people ------------------------------------------------------
my @people = read_people($PEOPLE_FILE);
die "No people in $PEOPLE_FILE\n" unless @people;
$_->{slug} //= slugify( $_->{name} ) for @people;   # tolerate hand-edited YAML
@people = sort { $a->{slug} cmp $b->{slug} } @people;
say "Read " . scalar(@people) . " people, " . scalar(@templates) . " template(s) from $PEOPLE_FILE";

if ($DRY_RUN) {
    say sprintf("  %-28s %-28s %s", 'SLUG', 'NAME', 'TITLE');
    say sprintf("  %-28s %-28s %s", $_->{slug}, $_->{name}, $_->{title}) for @people;
    say "DRY_RUN: nothing rendered.";
    exit 0;
}

# Stored fingerprints from the previous run, keyed by slug.
my %manifest = %{ read_manifest("$OUTPUT_DIR/manifest.json") };

# ---- 2. prune people who left --------------------------------------------
my %valid_slug = map { $_->{slug} => 1 } @people;
if (-d $OUTPUT_DIR) {
    opendir(my $dh, $OUTPUT_DIR) or die "opendir $OUTPUT_DIR: $!";
    for my $entry (sort readdir $dh) {
        next if $entry =~ /^\./;
        # readdir yields raw bytes; decode so accented slugs match %valid_slug
        # (which is keyed by the decoded names read from the YAML).
        my $slug = decode_utf8($entry);
        my $path = "$OUTPUT_DIR/$slug";
        next unless -d $path;
        next if $valid_slug{$slug};
        say "Pruning '$slug' (no longer in people file)";
        remove_tree($path);
        delete $manifest{$slug};
    }
    closedir $dh;
}

# ---- 3. render backgrounds whose content changed -------------------------
my $logo_uri = build_logo_uri($LOGO_PATH);
my $rendered = 0;
for my $person (@people) {
    my $slug = $person->{slug};
    my $dir  = "$OUTPUT_DIR/$slug";
    make_path($dir);
    for my $tpl (@templates) {
        (my $tname = basename($tpl)) =~ s/\.svg$//;
        my $out    = "$dir/$tname.png";
        my $filled = fill_one($tpl, $person, $logo_uri);
        my $new_fp = fingerprint($filled);
        my $old_fp = $manifest{$slug}{renders}{$tname};
        if (needs_render($FORCE, -e $out, $old_fp, $new_fp)) {
            rasterize($filled, $out);
            say "  rendered $slug/$tname.png";
            $rendered++;
        }
        $manifest{$slug}{renders}{$tname} = $new_fp;
    }
}

# ---- 4. manifest ---------------------------------------------------------
make_path($OUTPUT_DIR);
my @rows = map {
    +{
        slug    => $_->{slug},
        name    => $_->{name},
        title   => $_->{title},
        renders => ( $manifest{ $_->{slug} }{renders} // {} ),
    }
} @people;
my $json = JSON::PP->new->utf8->canonical->pretty->encode(\@rows);
open(my $mf, '>:raw', "$OUTPUT_DIR/manifest.json") or die $!;
print $mf $json;
close $mf;

say "Done. Rendered $rendered new file(s).";

# ==========================================================================
# Read a template and substitute the per-person placeholders; return the filled SVG.
sub fill_one {
    my ($tpl, $person, $logo) = @_;
    open(my $tf, '<:encoding(UTF-8)', $tpl) or die "read $tpl: $!";
    local $/; my $svg = <$tf>; close $tf;

    return fill_template($svg, {
        NAME        => xml_escape($person->{name}),
        TITLE       => xml_escape($person->{title}),
        NAME_UPPER  => xml_escape(uc_safe($person->{name})),
        TITLE_UPPER => xml_escape(uc_safe($person->{title})),
        LOGO        => $logo,
    });
}

# Rasterize a filled SVG string to a 1920x1080 PNG via rsvg-convert, then make
# sure it fits under the platform file-size cap.
sub rasterize {
    my ($filled, $out) = @_;
    my $tmp = "$out.tmp.svg";
    open(my $fh, '>:encoding(UTF-8)', $tmp) or die "write $tmp: $!";
    print $fh $filled;
    close $fh;

    my $rc = system('rsvg-convert', '-w', $WIDTH, '-h', $HEIGHT, '-o', $out, $tmp);
    unlink $tmp;
    die "rsvg-convert failed (exit @{[ $rc >> 8 ]}) for $out\n" if $rc != 0;

    shrink_to_limit($out, $MAX_BYTES);
}

# Keep a rendered PNG under the file-size cap. Optimizes in place with pngquant
# when available; dies if the result still won't fit, so a too-heavy template is
# caught here rather than producing a background some platforms reject.
sub shrink_to_limit {
    my ($out, $max) = @_;
    return if within_size_limit(-s $out, $max);

    if (`command -v pngquant 2>/dev/null`) {
        # Quantize in place; --skip-if-larger leaves the original if it can't help.
        system('pngquant', '--force', '--skip-if-larger', '--strip',
               '--quality=40-95', '--output', $out, '--', $out);
    }

    die sprintf(
        "%s is %.1f MB, over the %.1f MB limit — simplify the template "
            . "(e.g. shrink any embedded raster image) or raise MAX_BYTES\n",
        $out, ( -s $out ) / 1_000_000, $max / 1_000_000
    ) unless within_size_limit(-s $out, $max);
}

# Load the previous manifest into { slug => { name, title, renders => {tpl=>sha} } }.
# Tolerates a missing, corrupt, or old-schema (no "renders") file by treating
# whatever it can't use as empty.
sub read_manifest {
    my $path = shift;
    my %m;
    return \%m unless -e $path;
    my $data = eval {
        open(my $fh, '<:raw', $path) or die "read $path: $!\n";
        local $/; my $bytes = <$fh>; close $fh;
        JSON::PP->new->utf8->decode($bytes);
    };
    return \%m unless ref $data eq 'ARRAY';
    for my $row (@$data) {
        next unless ref $row eq 'HASH' && defined $row->{slug};
        $m{ $row->{slug} } = {
            name    => $row->{name}  // '',
            title   => $row->{title} // '',
            renders => ( ref $row->{renders} eq 'HASH' ? $row->{renders} : {} ),
        };
    }
    return \%m;
}
