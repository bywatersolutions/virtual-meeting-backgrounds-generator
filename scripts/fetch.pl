#!/usr/bin/env perl
#
# fetch.pl — stage 1: scrape the team page and write the people data to YAML.
#
# This is the only stage that touches the network. It fetches the about-us page,
# parses each person's name (p.name) + title (p.title), and writes them to a YAML
# file. Stage 2 (render.pl) reads that YAML and renders the images offline.
#
# Environment overrides:
#   ABOUT_URL    source page; http(s) URL, file:// URL, or local path
#                (default: https://bywatersolutions.com/about-us)
#   PEOPLE_FILE  output YAML path (default: <repo>/data/people.yaml)
#   DRY_RUN      truthy => print the parsed people; don't write the file
#
use strict;
use warnings;
use feature 'say';
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";
use File::Spec;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use ByWater::MeetingBackgrounds qw(slugify squish);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

# ---- configuration -------------------------------------------------------
my $ROOT        = File::Spec->rel2abs("$RealBin/..");
my $URL         = $ENV{ABOUT_URL}   // 'https://bywatersolutions.com/about-us';
my $PEOPLE_FILE = $ENV{PEOPLE_FILE} // "$ROOT/data/people.yaml";
my $DRY_RUN     = $ENV{DRY_RUN} ? 1 : 0;

# ---- fetch + parse -------------------------------------------------------
say "Source: $URL";
my @people = parse_people(fetch_html($URL));
die "No people parsed — has the page markup changed?\n" unless @people;
@people = sort { $a->{slug} cmp $b->{slug} } @people;
say "Parsed " . scalar(@people) . " people.";

if ($DRY_RUN) {
    say sprintf("  %-28s %-28s %s", 'SLUG', 'NAME', 'TITLE');
    say sprintf("  %-28s %-28s %s", $_->{slug}, $_->{name}, $_->{title}) for @people;
    say "DRY_RUN: nothing written.";
    exit 0;
}

# ---- write people.yaml ---------------------------------------------------
make_path(dirname($PEOPLE_FILE));
my $n = write_people($PEOPLE_FILE, \@people);
say "Wrote $n people to $PEOPLE_FILE";

# ==========================================================================
sub fetch_html {
    my $url = shift;
    if ($url =~ m{^file://(.*)$} || $url !~ m{^[a-z]+://}i) {
        my $path = $url =~ m{^file://(.*)$} ? $1 : $url;
        open(my $fh, '<:encoding(UTF-8)', $path) or die "read $path: $!";
        local $/; my $c = <$fh>; close $fh; return $c;
    }
    require Mojo::UserAgent;
    my $ua = Mojo::UserAgent->new;
    $ua->transactor->name('Background-Bot/1.0');
    $ua->max_redirects(5);
    my $res = $ua->get($url)->result;
    die "Fetch failed: " . $res->code . " " . $res->message . "\n" unless $res->is_success;
    return $res->body;
}

# Parse the team-page HTML into a list of { name, title, slug } hashrefs. Each
# person is a p.name with the nearest following p.title sibling (falling back to a
# p.title in the same parent container). This is specific to the about-us markup,
# so it lives here in the scraper rather than the shared module.
sub parse_people {
    my ($html) = @_;
    require Mojo::DOM;
    my $dom = Mojo::DOM->new($html);
    my @people;
    for my $name_el ($dom->find('p.name')->each) {
        my $name = squish($name_el->all_text);
        next unless length $name;
        my $title_el = $name_el->following('p.title')->first
                     || ($name_el->parent ? $name_el->parent->at('p.title') : undef);
        my $title = $title_el ? squish($title_el->all_text) : '';
        push @people, { name => $name, title => $title, slug => slugify($name) };
    }
    return @people;
}

# Write a list of { name, title, slug } hashrefs to a YAML file, sorted by slug
# for deterministic diffs. Returns the number of people written. This is the
# hand-off to stage 2 (render.pl reads it back via read_people).
sub write_people {
    my ( $path, $people ) = @_;
    require YAML::PP;
    my @rows = map { { name => $_->{name}, title => $_->{title}, slug => $_->{slug} } }
               sort { $a->{slug} cmp $b->{slug} } @$people;
    YAML::PP->new->dump_file( $path, \@rows );
    return scalar @rows;
}
