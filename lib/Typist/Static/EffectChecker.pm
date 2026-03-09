package Typist::Static::EffectChecker;
use v5.40;

our $VERSION = '0.01';

use Typist::Static::Timing;
use Typist::Type::Row;
use Typist::Type::Eff;
use Typist::Prelude;
use Scalar::Util 'refaddr';

# ── Perl Builtins ────────────────────────────

my %BUILTINS = map { $_ => 1 } Typist::Prelude->builtin_names;

# PPI-based static effect checker.
# Verifies that each function's body only calls functions whose effects
# are included in the caller's declared effect row.

sub new ($class, %args) {
    bless +{
        registry  => $args{registry},
        errors    => $args{errors},
        extracted => $args{extracted},
        ppi_doc   => $args{ppi_doc},
        file      => $args{file} // '(buffer)',
        timings   => $args{timings},
    }, $class;
}

sub _setup ($self) {
    $self->{_pkg} = $self->{extracted}{package};
}

sub check_function :TIMED_ACC(function_checks.effects) ($self, $name) {
    my $fn    = $self->{extracted}{functions}{$name};
    my $block = $fn->{block} // return;

    # Skip unannotated callers — gradual typing: no annotation = no constraint
    return if $fn->{unannotated};

    # Lookup the caller's registered sig
    my $caller_sig = $self->{registry}->lookup_function($self->{_pkg}, $name);
    return unless $caller_sig;

    my $caller_eff = $caller_sig->{effects};

    # Collect called functions and their effects
    my @called = $self->_collect_called_effects($fn, $self->{_pkg});

    # Scan for handle blocks that discharge effects
    my @handle_scopes = $self->_scan_handle_scopes($block);

    for my $call (@called) {
        my $callee_eff = $call->{effects};
        next unless $callee_eff;

        # Filter out discharged labels: if the call is inside a handle block
        # that handles a given effect, that label is consumed and need not
        # appear in the caller's annotation.
        my $effective_eff = $callee_eff;
        if (@handle_scopes && $call->{word}) {
            my $callee_row = $callee_eff->is_eff ? $callee_eff->row : $callee_eff;
            if ($callee_row->is_row) {
                my @remaining = grep {
                    $self->{registry}->is_ambient_effect($_)
                    || !$self->_is_discharged($call->{word}, $_, \@handle_scopes)
                } $callee_row->labels;
                # All labels discharged or ambient → skip this call entirely
                next if !@remaining;
                # Some labels remain → build a reduced row for checking
                if (@remaining < scalar($callee_row->labels)) {
                    my $reduced_row = Typist::Type::Row->new(
                        labels  => \@remaining,
                        row_var => $callee_row->row_var,
                    );
                    $effective_eff = Typist::Type::Eff->new($reduced_row);
                }
            }
        }

        # Caller has no effects declared but callee does
        unless ($caller_eff) {
            # Skip if all callee labels are ambient (IO/Exn/Decl — no handler needed)
            my $eff_row = $effective_eff->is_eff ? $effective_eff->row : $effective_eff;
            if ($eff_row->is_row) {
                my @labels = $eff_row->labels;
                my $all_ambient = @labels && !grep { !$self->{registry}->is_ambient_effect($_) } @labels;
                next if $all_ambient;
            }

            $self->{errors}->collect(
                kind    => 'EffectMismatch',
                message => "Function $name() calls $call->{name}() which requires "
                         . $effective_eff->to_string
                         . ", but $name() has no effect annotation",
                file    => $self->{file},
                line    => $call->{line},
                col     => $call->{col} // 0,
                end_col => ($call->{col} // 0) + length($call->{name}),
                explanation => [
                    "Caller: $name() has no declared effect row",
                    "Callee: $call->{name}() requires " . $effective_eff->to_string,
                    "Add the callee effects to the caller annotation or route the call through a handler",
                ],
            );
            next;
        }

        # Check effect inclusion: callee's labels ⊆ caller's labels
        $self->_check_effect_inclusion(
            $caller_eff, $effective_eff,
            $name, $call->{name}, $call->{line}, $call->{col} // 0,
        );
    }
}

sub analyze ($self) {
    $self->_setup;
    for my $name (sort keys $self->{extracted}{functions}->%*) {
        $self->check_function($name);
    }
}

sub _collect_called_effects ($self, $fn, $pkg) {
    my @calls;
    my $words = $fn->{block_words} // [];

    for my $word (@$words) {
        my $callee_name = $word->content;

        # Skip keywords
        next if $callee_name =~ /\A(?:my|our|local|return|if|unless|for|foreach|while|until|do|sub|use|no|handle|match)\z/;

        # Skip if it's a sub declaration
        my $parent = $word->parent;
        next if $parent && $parent->isa('PPI::Statement::Sub');

        # Skip method calls: ->name
        my $prev = $word->sprevious_sibling;
        next if $prev && ref $prev && $prev->isa('PPI::Token::Operator') && $prev->content eq '->';

        # Skip hash keys: name => ...
        my $next = $word->snext_sibling;
        next if $next && ref $next && $next->isa('PPI::Token::Operator') && $next->content eq '=>';

        # Builtin functions: check CORE registry for declared effects.
        # Builtins can be called without parens (say "hello"), so no List check needed.
        if ($BUILTINS{$callee_name}) {
            my $declared_sig = $self->{registry}->lookup_function('CORE', $callee_name);
            if ($declared_sig && $declared_sig->{effects}) {
                my $eff = $declared_sig->{effects};
                my $row = $eff->is_eff ? $eff->row : $eff;

                # Skip unannotated builtins (row_var '*') — pure
                unless ($row->is_row && ($row->row_var_name // '') eq '*') {
                    push @calls, +{
                        name    => $callee_name,
                        effects => $eff,
                        line    => $word->line_number,
                        col     => $word->column_number,
                        word    => $word,
                    };
                }
            }
            # else: no declaration or declared pure → skip (pure)
            next;
        }

        # Must be followed by a list (function call pattern)
        next unless $next && ref $next && $next->isa('PPI::Structure::List');

        # Look up callee's sig — local package, cross-package, then CORE
        my $callee_sig = $self->{registry}->lookup_function($pkg, $callee_name);
        unless ($callee_sig) {
            if ($callee_name =~ /\A(.+)::(\w+)\z/) {
                $callee_sig = $self->{registry}->lookup_function($1, $2);
            }
        }
        $callee_sig //= $self->{registry}->lookup_function('CORE', $callee_name);
        next unless $callee_sig;
        next unless $callee_sig->{effects};

        # Unannotated functions (row_var '*') are treated as pure → skip
        my $eff = $callee_sig->{effects};
        my $row = $eff->is_eff ? $eff->row : $eff;
        next if $row->is_row && ($row->row_var_name // '') eq '*';

        push @calls, +{
            name    => $callee_name,
            effects => $eff,
            line    => $word->line_number,
            col     => $word->column_number,
            word    => $word,
        };
    }

    @calls;
}

# Infer effects for unannotated functions (for LSP hints).
# Returns an arrayref of { name, labels => [...], unknown, line, col }.
sub infer_effects ($class_or_self, $extracted, $registry) {
    my @results;
    my $pkg = $extracted->{package} // 'main';

    # Build a temporary instance for _collect_called_effects
    my $checker = ref $class_or_self
        ? $class_or_self
        : bless +{ registry => $registry, extracted => $extracted }, $class_or_self;

    for my $name (sort keys $extracted->{functions}->%*) {
        my $fn = $extracted->{functions}{$name};
        next unless $fn->{unannotated};
        my $block = $fn->{block} // next;

        my @called = $checker->_collect_called_effects($fn, $pkg);
        my @handle_scopes = $checker->_scan_handle_scopes($block);
        my (%labels, $unknown);

        for my $call (@called) {
            my $eff = $call->{effects};
            next unless ref $eff;
            my $row = $eff->is_eff ? $eff->row : $eff;
            next unless $row->is_row;
            for my $label ($row->labels) {
                next if @handle_scopes && $call->{word}
                    && $checker->_is_discharged($call->{word}, $label, \@handle_scopes);
                $labels{$label} = 1;
            }
        }

        my @sorted = sort keys %labels;
        next unless @sorted || $unknown;

        push @results, +{
            name     => $name,
            labels   => \@sorted,
            unknown  => $unknown ? 1 : 0,
            line     => $fn->{line},
            col      => $fn->{col},
            name_col => $fn->{name_col},
        };
    }

    \@results;
}

# ── Handle-aware effect discharge ──────────────
#
# Scan a function's block for `handle { BODY } Effect => +{...}` patterns.
# Returns a list of { body => PPI::Structure::Block, effect => $label }.
# Used to determine which effect labels are discharged within handle scopes.

sub _scan_handle_scopes ($self, $block) {
    my @scopes;
    my $words = $block->find('PPI::Token::Word') || [];
    for my $word (@$words) {
        next unless $word->content eq 'handle';
        my $body = $word->snext_sibling;
        next unless $body && ref $body && $body->isa('PPI::Structure::Block');
        my @labels = _detect_handle_effects($body);
        for my $label (@labels) {
            push @scopes, +{ body => $body, effect => $label };
        }
    }
    @scopes;
}

# Detect which effects a handle block captures.
# Walks siblings after the body block for all 'Word =>' patterns.
sub _detect_handle_effects ($body) {
    my @effects;
    my $sib = $body->snext_sibling;
    while ($sib) {
        if (ref $sib && $sib->isa('PPI::Token::Word')) {
            my $next = $sib->snext_sibling;
            if ($next && ref $next && $next->isa('PPI::Token::Operator')
                && $next->content eq '=>')
            {
                push @effects, $sib->content;
            }
        }
        $sib = $sib->snext_sibling;
    }
    @effects;
}

# Check if a PPI word node is inside a handle body that discharges the given effect label.
sub _is_discharged ($self, $word, $label, $scopes) {
    for my $scope (@$scopes) {
        next unless $scope->{effect} eq $label;
        my $body_addr = refaddr($scope->{body});
        my $node = $word->parent;
        while ($node) {
            return 1 if refaddr($node) == $body_addr;
            $node = $node->parent;
        }
    }
    0;
}

sub _check_effect_inclusion ($self, $caller_eff, $callee_eff, $caller_name, $callee_name, $line, $col = 0) {
    my $caller_row = $caller_eff->is_eff ? $caller_eff->row : $caller_eff;
    my $callee_row = $callee_eff->is_eff ? $callee_eff->row : $callee_eff;

    # If either has row variables, skip (needs runtime unification)
    return if !$caller_row->is_closed || !$callee_row->is_closed;

    my %caller_labels = map { $_ => 1 } $caller_row->labels;

    for my $label ($callee_row->labels) {
        next if $self->{registry}->is_ambient_effect($label);
        unless ($caller_labels{$label}) {
            $self->{errors}->collect(
                kind    => 'EffectMismatch',
                message => "Function $caller_name() calls $callee_name() which requires "
                         . "effect '$label', but $caller_name() does not declare it",
                file    => $self->{file},
                line    => $line,
                col     => $col,
                end_col => $col + length($callee_name),
                explanation => [
                    "Caller effects: " . $caller_eff->to_string,
                    "Callee effects: " . $callee_eff->to_string,
                    "Missing effect label: $label",
                ],
            );
        }
    }
}

1;

__END__

=head1 NAME

Typist::Static::EffectChecker - Static effect label inclusion checker

=head1 DESCRIPTION

PPI-based checker that verifies each annotated function's body only calls
functions whose effect labels are a subset of the caller's declared effect row.
Unannotated functions are treated as pure under gradual typing and are skipped.

=head2 new

    my $ec = Typist::Static::EffectChecker->new(
        registry  => $registry,
        errors    => $error_collector,
        extracted => $extracted,
        ppi_doc   => $ppi_doc,
        file      => $filename,
    );

Construct a new EffectChecker for a single compilation unit.

=head2 analyze

    $ec->analyze;

Run effect-inclusion analysis over all annotated functions in the extracted
data.  For each callee with a declared effect row, verify that its labels
are included in the caller's declared row.  Collects C<EffectMismatch>
errors into the error collector.

=head2 infer_effects

    my $results = Typist::Static::EffectChecker->infer_effects($extracted, $registry);

Class method that infers effect labels for unannotated functions by scanning
their call graphs.  Returns an arrayref of hashrefs, each with C<name>,
C<labels>, C<line>, C<col>, and C<name_col> keys.  Used by LSP inlay hints
to display inferred effects.

=cut
