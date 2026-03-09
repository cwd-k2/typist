use v5.40;
use Test::More;
use lib 'lib';
use lib 't/lib';
use Test::Typist::LSP qw(make_doc);

# Test _word_at and _word_range_at consistency after dedup refactor.
# _word_at is now a thin wrapper over _word_range_at.

my $source = <<'PERL';
package MyPkg;
use v5.40;

my $foo = 42;
my @bar = (1, 2, 3);
sub greet ($name) { }
Typist::Type::Atom->new('Int');
PERL

my $doc = make_doc($source);

# ── _word_at basics ──────────────────────────────

subtest '_word_at — variable' => sub {
    # $foo is on line 3 (0-indexed), column 4 (on 'f')
    my $word = $doc->_word_at(3, 4);
    is $word, '$foo', 'variable name with sigil';
};

subtest '_word_at — bare word' => sub {
    # 'greet' on line 5
    my $word = $doc->_word_at(5, 5);
    is $word, 'greet', 'function name';
};

subtest '_word_at — qualified name' => sub {
    # Typist::Type::Atom on line 6
    my $word = $doc->_word_at(6, 5);
    like $word, qr/Typist::Type::Atom/, 'qualified package name';
};

subtest '_word_at — out of bounds' => sub {
    is $doc->_word_at(100, 0), undef, 'line out of bounds';
};

# ── _word_range_at ───────────────────────────────

subtest '_word_range_at — returns word and boundaries' => sub {
    my $result = $doc->_word_range_at(3, 4);
    ok defined $result, 'result defined';
    is ref $result, 'HASH', 'returns hashref';
    is $result->{word}, '$foo', 'word matches';
    ok $result->{start} < $result->{end}, 'start < end';
};

subtest '_word_range_at — consistency with _word_at' => sub {
    for my $line (0 .. 6) {
        for my $col (0 .. 30) {
            my $word  = $doc->_word_at($line, $col);
            my $range = $doc->_word_range_at($line, $col);
            if (defined $word) {
                ok defined $range, "range defined when word defined (line=$line col=$col)";
                is $range->{word}, $word, "words match (line=$line col=$col)";
            } else {
                ok !defined $range, "both undef (line=$line col=$col)";
            }
        }
    }
};

subtest '_word_range_at — sigil position' => sub {
    # Cursor on $ of $foo (column 3)
    my $result = $doc->_word_range_at(3, 3);
    ok defined $result, 'result from sigil position';
    is $result->{word}, '$foo', 'expanded from sigil';
};

done_testing;
