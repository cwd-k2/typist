use v5.40;
use Test::More;
use lib 'lib';

use Typist::Static::Analyzer;

my $source = <<'PERL';
use v5.40;
effect Logger => +{
    log_msg => '(Str) -> Void',
};

typeclass Show with [show => '(a) -> Str'];

datatype State => Ready => '()', Busy => '()';

sub demo :sig((State) -> Int ![Logger]) ($s) {
    match $s,
        Ready => sub { perform Logger::log_msg("ready"); 1 },
        Busy  => sub { 2 };
}
PERL

my $result = Typist::Static::Analyzer->analyze(
    $source,
    file           => 'timings.pm',
    collect_timing => 1,
);

ok $result->{timings}, 'timings returned';
ok exists $result->{timings}{structural}, 'top-level structural timing exists';
ok exists $result->{timings}{'structural.aliases'}, 'alias timing exists';
ok exists $result->{timings}{'structural.functions'}, 'function timing exists';
ok exists $result->{timings}{'structural.functions.free_vars'}, 'free var timing exists';
ok exists $result->{timings}{'structural.functions.effects'}, 'effect timing exists';
ok exists $result->{timings}{'structural.functions.kinds'}, 'kind timing exists';
ok exists $result->{timings}{'structural.typeclasses'}, 'typeclass timing exists';
ok exists $result->{timings}{'structural.protocols'}, 'protocol timing exists';
ok exists $result->{timings}{'file_checks.variables'}, 'variables timing exists';
ok exists $result->{timings}{'file_checks.assignments'}, 'assignments timing exists';
ok exists $result->{timings}{'file_checks.call_sites'}, 'call_sites timing exists';
ok exists $result->{timings}{'file_checks.match_exhaustiveness'}, 'match timing exists';
ok exists $result->{timings}{'function_checks.returns'}, 'returns timing exists';
ok exists $result->{timings}{'function_checks.effects'}, 'effects timing exists';
ok exists $result->{timings}{'function_checks.protocols'}, 'protocols timing exists';
ok exists $result->{timings}{'function_checks.handle_blocks'}, 'handle_blocks timing exists';

ok $result->{timings}{structural} >= 0, 'structural timing is numeric';
ok $result->{timings}{'structural.functions.total'} >= 0, 'function total timing is numeric';

done_testing;
