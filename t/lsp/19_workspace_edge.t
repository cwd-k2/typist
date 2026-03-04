use v5.40;
use Test::More;
use lib 'lib';

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Typist::LSP::Workspace;
use Typist::LSP::Logger;

my $logger = Typist::LSP::Logger->new(level => 'off');

# ── Empty workspace ─────────────────────────────

subtest 'empty workspace' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    ok $ws, 'workspace created for empty dir';
    is_deeply [$ws->all_typedef_names], [], 'no typedefs';
    is_deeply [$ws->all_constructor_names], [], 'no constructors';

    # Registry should still have prelude
    my $reg = $ws->registry;
    ok $reg, 'registry exists';
};

# ── Syntax error graceful degradation ───────────

subtest 'syntax error file does not crash workspace' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    # Write a file with valid typist content
    open my $fh1, '>', "$dir/lib/Good.pm" or die;
    print $fh1 <<'PERL';
package Good;
use v5.40;
typedef Name => 'Str';
1;
PERL
    close $fh1;

    # Write a file with broken syntax
    open my $fh2, '>', "$dir/lib/Bad.pm" or die;
    print $fh2 <<'PERL';
package Bad;
use v5.40;
typedef Broken =>
PERL
    close $fh2;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    ok $ws, 'workspace survives syntax error file';

    my @names = $ws->all_typedef_names;
    ok((grep { $_ eq 'Name' } @names), 'Good.pm types still registered');
};

# ── Cross-file newtype resolution ───────────────

subtest 'cross-file newtype resolution' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh1, '>', "$dir/lib/Types.pm" or die;
    print $fh1 <<'PERL';
package Types;
use v5.40;
newtype UserId => 'Int';
1;
PERL
    close $fh1;

    open my $fh2, '>', "$dir/lib/Service.pm" or die;
    print $fh2 <<'PERL';
package Service;
use v5.40;
sub get_user :sig((UserId) -> Str) ($id) { "user_$id" }
1;
PERL
    close $fh2;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    ok $ws->registry->lookup_newtype('UserId'), 'UserId newtype registered';

    # Function should be discoverable
    my $fn = $ws->registry->search_function_by_name('get_user');
    ok $fn, 'get_user found in registry';
};

# ── Cross-file effect resolution ────────────────

subtest 'cross-file effect resolution' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Effects.pm" or die;
    print $fh <<'PERL';
package Effects;
use v5.40;
effect Logger => +{
    log_msg => '(Str) -> Void',
};
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    my @effects = $ws->all_effect_names;
    ok((grep { $_ eq 'Logger' } @effects), 'Logger effect found');

    my $eff = $ws->registry->lookup_effect('Logger');
    ok $eff, 'Logger effect resolves';
};

# ── Differential update: add then remove ────────

subtest 'differential update: add then remove type' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Evolving.pm" or die;
    print $fh <<'PERL';
package Evolving;
use v5.40;
typedef Score => 'Int';
typedef Level => 'Str';
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");

    my @names = $ws->all_typedef_names;
    ok((grep { $_ eq 'Score' } @names), 'Score initially present');
    ok((grep { $_ eq 'Level' } @names), 'Level initially present');

    # Update: remove Score, keep Level, add Rank
    $ws->update_file("$dir/lib/Evolving.pm", <<'PERL');
package Evolving;
use v5.40;
typedef Level => 'Str';
typedef Rank  => 'Int';
1;
PERL

    my @updated_names = $ws->all_typedef_names;
    ok(!(grep { $_ eq 'Score' } @updated_names), 'Score removed after update');
    ok((grep { $_ eq 'Level' } @updated_names), 'Level preserved');
    ok((grep { $_ eq 'Rank' } @updated_names), 'Rank added');

    # Verify Score no longer resolves
    ok !$ws->registry->has_alias('Score'), 'Score alias unregistered';
};

# ── Struct cross-file ──────────────────────────

subtest 'cross-file struct registration' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Models.pm" or die;
    print $fh <<'PERL';
package Models;
use v5.40;
struct Person => (name => Str, age => Int);
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    my @constructors = $ws->all_constructor_names;
    ok((grep { $_ eq 'Person' } @constructors), 'Person constructor found');

    my $st = $ws->registry->lookup_struct('Person');
    ok $st, 'Person struct resolves';
};

# ── find_definition ─────────────────────────────

subtest 'find_definition for typedef' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/lib");

    open my $fh, '>', "$dir/lib/Defs.pm" or die;
    print $fh <<'PERL';
package Defs;
use v5.40;
typedef Color => 'Str';
1;
PERL
    close $fh;

    my $ws = Typist::LSP::Workspace->new(root => "$dir/lib");
    my $def = $ws->find_definition('Color');
    ok $def, 'definition found for Color';
    like $def->{uri}, qr/Defs\.pm/, 'uri points to Defs.pm';
};

done_testing;
