package Typist::Static::ProtocolChecker;
use v5.40;

our $VERSION = '0.01';

use Typist::Static::Timing;

# Static protocol state-machine checker.
# Verifies that effect operations are called in the correct order
# according to the protocol's finite state machine.
# State is tracked as a set (arrayref of state names).
# Supports branching (union), loop idempotency, handle auto * -> *, match arms.

# ── Set utilities ────────────────────────────────

sub _state_eq ($a, $b)       { "@{[sort @$a]}" eq "@{[sort @$b]}" }
sub _state_union (@sets)     { my %s; $s{$_}=1 for map { @$_ } @sets; [sort keys %s] }
sub _state_subset ($sub,$sup){ my %s = map {$_=>1} @$sup; !grep {!$s{$_}} @$sub }
sub _state_fmt ($set)        { join(' | ', @$set) }

sub new ($class, %args) {
    bless +{
        registry  => $args{registry},
        errors    => $args{errors},
        extracted => $args{extracted},
        ppi_doc   => $args{ppi_doc},
        file      => $args{file} // '(buffer)',
        timings   => $args{timings},
        hints     => [],
    }, $class;
}

sub hints ($self) { $self->{hints} }

sub _setup ($self) {
    $self->{_pkg} = $self->{extracted}{package};
    $self->{_checked_handles} = {};
}

sub check_function :TIMED_ACC(function_checks.protocols) ($self, $name) {
    my $fn = $self->{extracted}{functions}{$name};
    return if $fn->{unannotated};
    my $block = $fn->{block} // return;

    my $caller_sig = $self->{registry}->lookup_function($self->{_pkg}, $name);
    return unless $caller_sig;
    return unless $caller_sig->{effects};

    my $caller_eff = $caller_sig->{effects};
    my $row = $caller_eff->is_eff ? $caller_eff->row : $caller_eff;
    return unless $row->is_row;

    # For each label with protocol state annotation, trace the body
    for my $label ($row->labels) {
        my $base = Typist::Type::Row->label_base_name($label);
        my $state_range = $row->label_state($label);
        unless ($state_range) {
            my $effect = $self->{registry}->lookup_effect($base);
            next unless $effect && $effect->has_protocol;
            # ![DB] without state annotation defaults to * -> *
            $state_range = { from => ['*'], to => ['*'] };
        }
        my $effect = $self->{registry}->lookup_effect($base);
        next unless $effect && $effect->has_protocol;

        my $protocol = $effect->protocol;
        $self->{_checked_handles}{"$name\0$base"} = 1;
        $self->_trace_body(
            $block, $name, $label, $protocol,
            $state_range->{from}, $state_range->{to}, $self->{_pkg},
        );
    }
}

sub check_handle_blocks :TIMED(function_checks.handle_blocks) ($self) {
    $self->{_relaxed_handle} = 1;
    $self->_check_handle_blocks($self->{_pkg});
    delete $self->{_relaxed_handle};
}

sub analyze ($self) {
    $self->_setup;
    for my $name (sort keys $self->{extracted}{functions}->%*) {
        $self->check_function($name);
    }
    $self->check_handle_blocks;
}

sub _check_handle_blocks ($self, $pkg) {
    for my $name (sort keys $self->{extracted}{functions}->%*) {
        my $fn = $self->{extracted}{functions}{$name};
        my $block = $fn->{block} // next;
        $self->_scan_handles($block, $name, $pkg);
    }
}

sub _scan_handles ($self, $block, $fn_name, $pkg) {
    for my $child ($block->schildren) {
        if ($child->isa('PPI::Statement::Compound')) {
            my @blocks = grep { $_->isa('PPI::Structure::Block') } $child->schildren;
            $self->_scan_handles($_, $fn_name, $pkg) for @blocks;
            next;
        }
        next unless $child->isa('PPI::Statement');

        my @words = grep { $_->isa('PPI::Token::Word') } $child->schildren;
        for my $word (@words) {
            next unless $word->content eq 'handle';
            my $body = $word->snext_sibling;
            next unless $body && ref $body && $body->isa('PPI::Structure::Block');

            my $label = _detect_handle_effect($body);
            next unless defined $label;
            next if $self->{_checked_handles}{"$fn_name\0$label"};

            my $base_label = Typist::Type::Row->label_base_name($label);
            my $effect = $self->{registry}->lookup_effect($base_label);
            next unless $effect && $effect->has_protocol;

            my $protocol = $effect->protocol;
            $self->{_checked_handles}{"$fn_name\0$label"} = 1;
            $self->_trace_body(
                $block, $fn_name, $label, $protocol,
                ['*'], ['*'], $pkg,
            );
        }
    }
}

sub _trace_body ($self, $block, $fn_name, $label, $protocol, $from, $to, $pkg) {
    my $result = $self->_trace_block($block, $fn_name, $label, $protocol, $from, $pkg);
    return if $result->{error};

    # If all paths return, no final state check needed
    return if $result->{returns};

    my $current = $result->{state};
    unless (_state_eq($current, $to)) {
        $self->{errors}->collect(
            kind    => 'ProtocolMismatch',
            message => "Protocol $label: function $fn_name() ends in state '"
                     . _state_fmt($current) . "' "
                     . "but declared end state is '" . _state_fmt($to) . "'",
            file    => $self->{file},
            line    => $self->{extracted}{functions}{$fn_name}{line},
            col     => $self->{extracted}{functions}{$fn_name}{col},
        );
    }
}

# Trace a block, walking its direct children (statements).
# $current is an arrayref of state names.
# Returns { state => $final } or { returns => 1 } or { error => 1 }.
sub _trace_block ($self, $block, $fn_name, $label, $protocol, $current, $pkg) {
    for my $child ($block->schildren) {
        if ($child->isa('PPI::Statement::Compound')) {
            my $result = $self->_trace_compound(
                $child, $fn_name, $label, $protocol, $current, $pkg,
            );
            return $result if $result->{error} || $result->{returns};
            $current = $result->{state};
            next;
        }

        if ($child->isa('PPI::Statement')) {
            # Check for return keyword
            my $first = $child->schild(0);
            if ($first && $first->isa('PPI::Token::Word') && $first->content eq 'return') {
                return +{ state => $current, returns => 1 };
            }

            my $result = $self->_trace_statement(
                $child, $fn_name, $label, $protocol, $current, $pkg,
            );
            return $result if $result->{error};
            $current = $result->{state};
        }
    }

    +{ state => $current };
}

# Trace a compound statement (if/elsif/else, while, for).
# Branches produce a union of end states.
sub _trace_compound ($self, $compound, $fn_name, $label, $protocol, $current, $pkg) {
    my @blocks = grep { $_->isa('PPI::Structure::Block') } $compound->schildren;
    return +{ state => $current } unless @blocks;

    # Detect if this is a conditional (if/unless/elsif/else)
    my ($keyword) = grep { $_->isa('PPI::Token::Word') } $compound->schildren;
    my $kw = $keyword ? $keyword->content : '';
    my $is_conditional = $kw =~ /\A(?:if|unless|elsif)\z/;

    unless ($is_conditional) {
        # For loops: body must be idempotent (end state = start state).
        # The loop may execute zero times, so the entry state is preserved.
        my $result = $self->_trace_block($blocks[0], $fn_name, $label, $protocol, $current, $pkg);
        return $result if $result->{error};

        if (!$result->{returns} && !_state_eq($result->{state}, $current)) {
            $self->{errors}->collect(
                kind    => 'ProtocolMismatch',
                message => "Protocol $label: loop body changes state from '"
                         . _state_fmt($current) . "' "
                         . "to '" . _state_fmt($result->{state})
                         . "' — must be idempotent (in $fn_name())",
                file    => $self->{file},
                line    => $compound->line_number,
                col     => $compound->column_number,
            );
            return +{ error => 1 };
        }

        return +{ state => $current };
    }

    # Count else keywords to determine if we have an else branch
    my @keywords = grep { $_->isa('PPI::Token::Word') } $compound->schildren;
    my $has_else = grep { $_->content eq 'else' } @keywords;

    my @branch_states;
    my $all_return = 1;

    for my $b (@blocks) {
        my $result = $self->_trace_block($b, $fn_name, $label, $protocol, $current, $pkg);
        return $result if $result->{error};

        if ($result->{returns}) {
            # This branch returns early — excluded from union
        } else {
            $all_return = 0;
            push @branch_states, $result->{state};
        }
    }

    # All branches return → propagate
    if ($all_return && $has_else) {
        return +{ returns => 1 };
    }

    # No else: the fallthrough path (no branch taken) has state $current
    unless ($has_else) {
        $all_return = 0;
        push @branch_states, $current;
    }

    # No non-returning branches: all returned but no else → only fallthrough
    return +{ state => $current } unless @branch_states;

    # Union of all branch end states
    +{ state => _state_union(@branch_states) };
}

# Detect which effect a handle block captures.
# Scans siblings after the block for 'Word => +{...}' pattern.
sub _detect_handle_effect ($body) {
    my $sib = $body->snext_sibling;
    while ($sib) {
        if (ref $sib && $sib->isa('PPI::Token::Word')) {
            my $next = $sib->snext_sibling;
            if ($next && ref $next && $next->isa('PPI::Token::Operator')
                && $next->content eq '=>')
            {
                return $sib->content;
            }
        }
        $sib = $sib->snext_sibling;
    }
    undef;
}

# Trace a single statement for protocol operations.
# $current is an arrayref of state names.
sub _trace_statement ($self, $stmt, $fn_name, $label, $protocol, $current, $pkg) {
    my @words = grep { $_->isa('PPI::Token::Word') } $stmt->schildren;
    my $label_base = Typist::Type::Row->label_base_name($label);

    for my $word (@words) {
        my $content = $word->content;

        # Pattern 1: Direct effect operation — Label::op(...)
        if ($content =~ /\A\Q${label_base}\E::(\w+)\z/) {
            my $op = $1;
            my $next = $word->snext_sibling;
            next unless $next && ref $next && $next->isa('PPI::Structure::List');

            my $next_state = $protocol->next_states($current, $op);
            if (!defined $next_state) {
                $self->{errors}->collect(
                    kind    => 'ProtocolMismatch',
                    message => "Protocol $label: operation '$op' is not allowed "
                             . "in state '" . _state_fmt($current) . "' (in $fn_name())",
                    file    => $self->{file},
                    line    => $word->line_number,
                    col     => $word->column_number,
                    end_col => $word->column_number + length($content),
                );
            } else {
                push $self->{hints}->@*, +{
                    label => $label,
                    op    => $op,
                    from  => $current,
                    to    => $next_state,
                    line  => $word->line_number,
                    col   => $word->column_number,
                };
                $current = $next_state;
            }
            next;
        }

        # handle { BODY } Effect => +{...}
        if ($content eq 'handle') {
            my $body = $word->snext_sibling;
            if ($body && ref $body && $body->isa('PPI::Structure::Block')) {
                my $handled = _detect_handle_effect($body);
                if (defined $handled && $handled eq $label_base) {
                    # Same effect: handle captures it → body traced at * -> *
                    my $r = $self->_trace_block($body, $fn_name, $label, $protocol, ['*'], $pkg);
                    unless ($self->{_relaxed_handle} || $r->{error} || $r->{returns} || _state_eq($r->{state}, ['*'])) {
                        $self->{errors}->collect(
                            kind    => 'ProtocolMismatch',
                            message => "Protocol $label: handle body must end at '*' "
                                     . "but ends at '" . _state_fmt($r->{state})
                                     . "' (in $fn_name())",
                            file    => $self->{file},
                            line    => $word->line_number,
                            col     => $word->column_number,
                        );
                    }
                    $current = ['*'];
                } else {
                    # Different effect → transparent pass-through
                    my $result = $self->_trace_block($body, $fn_name, $label, $protocol, $current, $pkg);
                    return $result if $result->{error};
                    $current = $result->{state} unless $result->{returns};
                }
            }
            next;
        }

        # match $val, Tag => sub { ... }: trace each arm, union the results
        if ($content eq 'match') {
            my @blocks;
            my $sib = $word->snext_sibling;
            while ($sib) {
                if (ref $sib && $sib->isa('PPI::Structure::Block')) {
                    push @blocks, $sib;
                }
                $sib = $sib->snext_sibling;
            }

            if (@blocks) {
                my @branch_states;
                my $all_return = 1;
                for my $b (@blocks) {
                    my $result = $self->_trace_block($b, $fn_name, $label, $protocol, $current, $pkg);
                    return $result if $result->{error};
                    if ($result->{returns}) {
                        # branch returns — excluded from union
                    } else {
                        $all_return = 0;
                        push @branch_states, $result->{state};
                    }
                }

                if ($all_return && @blocks) {
                    return +{ returns => 1 };
                }

                # Union of all branch end states
                if (@branch_states) {
                    $current = _state_union(@branch_states);
                }
            }
            next;
        }

        # Pattern 2: Function call with protocol annotation — f(...)
        next if $content =~ /\A(?:my|our|local|return|if|unless|for|foreach|while|until|do|sub|use|no)\z/;
        my $prev = $word->sprevious_sibling;
        next if $prev && ref $prev && $prev->isa('PPI::Token::Operator') && $prev->content eq '->';
        my $next_sib = $word->snext_sibling;
        next if $next_sib && ref $next_sib && $next_sib->isa('PPI::Token::Operator') && $next_sib->content eq '=>';
        next unless $next_sib && ref $next_sib && $next_sib->isa('PPI::Structure::List');

        my $callee_sig = $self->{registry}->lookup_function($pkg, $content);
        unless ($callee_sig) {
            if ($content =~ /\A(.+)::(\w+)\z/) {
                $callee_sig = $self->{registry}->lookup_function($1, $2);
            }
        }
        next unless $callee_sig && $callee_sig->{effects};

        my $callee_eff = $callee_sig->{effects};
        my $callee_row = $callee_eff->is_eff ? $callee_eff->row : $callee_eff;
        next unless $callee_row->is_row;

        my $callee_state = $callee_row->label_state($label) // next;
        # callee_state->{from} and {to} are arrayrefs

        if (!_state_subset($current, $callee_state->{from})) {
            $self->{errors}->collect(
                kind    => 'ProtocolMismatch',
                message => "Protocol $label: $content() expects state '"
                         . _state_fmt($callee_state->{from}) . "' "
                         . "but current state is '" . _state_fmt($current)
                         . "' (in $fn_name())",
                file    => $self->{file},
                line    => $word->line_number,
                col     => $word->column_number,
                end_col => $word->column_number + length($content),
            );
        } else {
            push $self->{hints}->@*, +{
                label => $label,
                op    => $content,
                from  => $current,
                to    => $callee_state->{to},
                line  => $word->line_number,
                col   => $word->column_number,
            };
            $current = $callee_state->{to};
        }
    }

    +{ state => $current };
}

1;

__END__

=head1 NAME

Typist::Static::ProtocolChecker - Static protocol state-machine verification

=head1 DESCRIPTION

Traces effect operation sequences in function bodies and verifies them
against the protocol finite state machine attached to each effect.  Supports
if/else branching convergence, loop idempotency enforcement, C<handle> body
tracing, C<match> arm convergence, and cross-function protocol composition.
Collects C<ProtocolMismatch> errors and state-transition hints for LSP.

=head2 new

    my $pc = Typist::Static::ProtocolChecker->new(
        registry  => $registry,
        errors    => $error_collector,
        extracted => $extracted,
        ppi_doc   => $ppi_doc,
        file      => $filename,
    );

Construct a new ProtocolChecker for a single compilation unit.

=head2 analyze

    $pc->analyze;

Run protocol verification over all annotated functions whose effect rows
contain protocol state annotations (C<< ![Label<From -E<gt> To>] >>).  Traces
each function body against the protocol FSM, checking that every operation
is allowed in the current state and that the final state matches the
declared end state.

=head2 hints

    my $hints = $pc->hints;

Return an arrayref of state-transition hint entries collected during
C<analyze>.  Each entry is a hashref with C<label>, C<op>, C<from>, C<to>,
C<line>, and C<col> keys, recording successful protocol transitions for
use by LSP inlay hints.

=cut
