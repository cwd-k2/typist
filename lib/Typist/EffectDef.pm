package Typist::EffectDef;
use v5.40;

our $VERSION = '0.01';

# Effect, handle, and protocol definitions.
# Extracted from Typist.pm for module decomposition.

# ── Protocol Support ────────────────────────────

sub _make_protocol (@args) {
    if (@args == 2 && !ref $args[0] && !ref $args[1]) {
        # protocol('(Str) -> Void', '* -> Connected')
        my ($sig, $trans) = @args;
        my ($lhs, $rhs) = $trans =~ /^\s*(.+?)\s*->\s*(.+?)\s*$/;
        die "Invalid protocol transition: '$trans'\n" unless defined $lhs;
        my @from = sort map { s/\s+//gr } split(/\s*\|\s*/, $lhs);
        my @to   = sort map { s/\s+//gr } split(/\s*\|\s*/, $rhs);
        return +{ __protocol__ => 1, sig => $sig, from => \@from, to => \@to };
    }
    die "Invalid protocol() call\n";
}

# ── Effect Support ──────────────────────────────

sub _effect ($name, @rest) {
    # Pop the operations hashref (always last argument)
    my $operations_ref = pop @rest;
    # Remaining strings are states (empty for protocol-less effects)
    my $states = @rest ? \@rest : undef;

    # Process operation values: string or protocol('sig', 'transition') hashref
    my (%ops, %transitions, %op_map);
    for my $op_name (keys %$operations_ref) {
        my $val = $operations_ref->{$op_name};
        if (ref $val eq 'HASH' && $val->{__protocol__}) {
            $ops{$op_name} = $val->{sig};
            $op_map{$op_name} = { from => $val->{from}, to => $val->{to} };
            for my $f ($val->{from}->@*) {
                $transitions{$f}{$op_name} = $val->{to}[0];
            }
        } else {
            $ops{$op_name} = $val;
        }
    }

    my $protocol;
    if (%transitions) {
        require Typist::Protocol;
        $protocol = Typist::Protocol->new(
            transitions => +{%transitions},
            op_map      => +{%op_map},
            ($states ? (states => $states) : ()),
        );
    }

    my $eff = Typist::Effect->new(
        name       => $name,
        operations => \%ops,
        protocol   => $protocol,
    );
    Typist::Registry->register_effect($name, $eff);

    # Install qualified subs for direct effect operation calls
    for my $op_name (keys %ops) {
        my ($eff_name, $op) = ($name, $op_name);
        no strict 'refs';
        *{"${eff_name}::${op}"} = sub (@args) {
            my $handler = Typist::Handler->find_handler($eff_name)
                // die "No handler for effect ${eff_name}::${op}\n";
            my $impl = $handler->{$op}
                // die "No handler for effect ${eff_name}::${op}\n";
            $impl->(@args);
        };
    }
}

# ── Handle Support (scoped effect handler block) ──
#
#   handle { BODY } Effect => +{ op => sub ... }, ...;
#
# The (&@) prototype allows bare-block syntax at call sites.

sub _handle :prototype(&@) {
    my ($body, @handler_specs) = @_;

    # Push all effect handlers onto the stack
    my $pushed = 0;
    while (@handler_specs >= 2) {
        my $effect   = shift @handler_specs;
        my $handlers = shift @handler_specs;
        Typist::Handler->push_handler($effect, $handlers);
        $pushed++;
    }

    # Execute body, ensuring handlers are popped even on exception
    my @result;
    my $ok = eval {
        @result = $body->();
        1;
    };
    my $err = $@;

    # Pop handlers (LIFO — matches push order)
    Typist::Handler->pop_handler for 1 .. $pushed;

    # Re-raise if body threw
    die $err unless $ok;

    wantarray ? @result : $result[0];
}

1;
