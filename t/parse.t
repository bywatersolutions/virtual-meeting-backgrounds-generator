use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

# Stage 1 lives in scripts/fetch.pl (parse_people + write_people are script-local),
# so this drives the script end-to-end against the offline fixture: scrape -> YAML,
# then read it back through the module's read_people and check the data.
BEGIN {
    eval { require Mojo::DOM; 1 }
        or plan skip_all => 'Mojo::DOM not installed (install libmojolicious-perl)';
    eval { require YAML::PP; 1 }
        or plan skip_all => 'YAML::PP not installed (install libyaml-pp-perl)';
}

use File::Temp qw(tempdir);
use ByWater::MeetingBackgrounds qw(read_people);

my $root    = "$RealBin/..";
my $fixture = "$root/test/fixtures/about-us.html";
my $dir     = tempdir( CLEANUP => 1 );
my $yaml    = "$dir/people.yaml";

local $ENV{ABOUT_URL}   = $fixture;
local $ENV{PEOPLE_FILE} = $yaml;
my $out = qx{perl -I"$root/lib" "$root/scripts/fetch.pl" 2>&1};
is $? >> 8, 0, 'fetch.pl exited cleanly' or diag $out;
like $out, qr/Wrote 4 people/, 'scraped and wrote the four team members (decoys ignored)';

my @people  = read_people($yaml);
my %by_slug = map { $_->{slug} => $_ } @people;

is scalar(@people), 4, 'YAML round-trips four people';

ok $by_slug{'Ada-Lovelace'}, 'Ada-Lovelace present';
is $by_slug{'Ada-Lovelace'}{title}, 'Test Engineer', 'title via following sibling';

ok $by_slug{'Alan-M-Turing'}, 'Alan-M-Turing present (middle initial + period)';
is $by_slug{'Alan-M-Turing'}{title},
   'Co-Owner & Chief Executive Officer', 'HTML entity decoded in title';

ok $by_slug{'Grace-Hopper'}, 'whitespace name slugged correctly';
is $by_slug{'Grace-Hopper'}{name},  'Grace Hopper',           'name squished';
is $by_slug{'Grace-Hopper'}{title}, 'Director of Migrations', 'title squished';

ok $by_slug{'Zoë-Example'} || $by_slug{'Zo-Example'},
   'accented name produced a slug';

done_testing;
