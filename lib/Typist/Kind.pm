package Typist::Kind;
use v5.40;

our $VERSION = '0.01';

# Kind system: Star and Arrow.
#   Star            — the kind of concrete types (e.g., Int, Str)
#   Arrow(from, to) — the kind of type constructors (e.g., ArrayRef : * -> *)

# ── Constructors ────────────────────────────────

sub Star ($class) {
    state $star = bless +{ kind => 'Star' }, "${class}::Star";
    $star;
}

sub Row ($class) {
    state $row = bless +{ kind => 'Row' }, "${class}::Row";
    $row;
}

sub Arrow ($class, $from, $to) {
    bless +{ from => $from, to => $to }, "${class}::Arrow";
}

# ── Parsing ─────────────────────────────────────

# Parse a kind expression like "* -> *" or "* -> * -> *"
sub parse ($class, $expr) {
    my @tokens = split /\s+/, $expr;
    my $pos = 0;
    _parse_kind(\@tokens, \$pos);
}

sub _parse_kind ($tokens, $pos) {
    my $left = _parse_primary($tokens, $pos);

    if ($$pos < @$tokens && $tokens->[$$pos] eq '->') {
        $$pos++;
        my $right = _parse_kind($tokens, $pos);  # right-associative
        return Typist::Kind->Arrow($left, $right);
    }

    $left;
}

sub _parse_primary ($tokens, $pos) {
    die "Kind: unexpected end of input" if $$pos >= @$tokens;
    my $tok = $tokens->[$$pos++];
    return Typist::Kind->Star if $tok eq '*';
    return Typist::Kind->Row  if $tok eq 'Row';
    die "Kind: expected '*' or 'Row', got '$tok'";
}

# ── Star Kind ───────────────────────────────────

package Typist::Kind::Star;
use v5.40;

sub to_string ($self) { '*' }

sub equals ($self, $other) {
    ref $other eq 'Typist::Kind::Star';
}

sub arity ($self) { 0 }

# ── Row Kind ────────────────────────────────────

package Typist::Kind::Row;
use v5.40;

sub to_string ($self) { 'Row' }

sub equals ($self, $other) {
    ref $other eq 'Typist::Kind::Row';
}

sub arity ($self) { 0 }

# ── Arrow Kind ──────────────────────────────────

package Typist::Kind::Arrow;
use v5.40;

sub from ($self) { $self->{from} }
sub to   ($self) { $self->{to} }

sub to_string ($self) {
    my $from_str = $self->{from}->to_string;
    my $to_str   = $self->{to}->to_string;
    # Parenthesize arrow-kinded left side for clarity
    $from_str = "($from_str)" if ref $self->{from} eq 'Typist::Kind::Arrow';
    "$from_str -> $to_str";
}

sub equals ($self, $other) {
    return 0 unless ref $other eq 'Typist::Kind::Arrow';
    $self->{from}->equals($other->from) && $self->{to}->equals($other->to);
}

sub arity ($self) {
    1 + $self->{to}->arity;
}

1;

=head1 NAME

Typist::Kind - Kind system for type constructors

=head1 SYNOPSIS

    use Typist::Kind;

    my $star  = Typist::Kind->Star;         # *
    my $row   = Typist::Kind->Row;          # Row
    my $arrow = Typist::Kind->Arrow($star, $star);  # * -> *

    my $kind = Typist::Kind->parse('* -> * -> *');

=head1 DESCRIPTION

Implements the kind system: C<Star> for concrete types, C<Row> for
effect rows, and C<Arrow> for type constructors. Kind expressions
like C<* -E<gt> *> describe type constructors that take one type
argument (e.g., C<ArrayRef>).

=head1 CONSTRUCTORS

=head2 Star

    my $k = Typist::Kind->Star;

Singleton kind for concrete types (C<*>).

=head2 Row

    my $k = Typist::Kind->Row;

Singleton kind for effect rows.

=head2 Arrow

    my $k = Typist::Kind->Arrow($from, $to);

Arrow kind representing type constructors.

=head2 parse

    my $k = Typist::Kind->parse('* -> *');

Parses a kind expression string. Right-associative.

=head1 KIND OBJECTS

All kind objects support C<to_string>, C<equals>, and C<arity>.

=head1 SEE ALSO

L<Typist::KindChecker>, L<Typist::TypeClass>

=cut
