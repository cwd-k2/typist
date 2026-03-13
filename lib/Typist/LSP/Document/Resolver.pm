package Typist::LSP::Document::Resolver;
use v5.40;

our $VERSION = '0.01';

use Typist::Parser;
use Typist::Static::SymbolInfo qw(sym_variable sym_field sym_method);

# ── Constructor ──────────────────────────────────

sub new ($class, %args) {
    bless +{
        result => $args{result},
        lines  => $args{lines},
    }, $class;
}

# ── Variable Type Resolution ────────────────────

# Resolve the type of a variable from analysis symbols.
# When $line (0-indexed LSP line) is given, prefer scoped symbols that
# contain the line and skip Any-typed entries when a better match exists.
sub resolve_var_type ($self, $var_name, $line = undef) {
    my $result = $self->{result} // return undef;
    my $symbols = $result->{symbols} // return undef;

    my $ppi_line = defined $line ? $line + 1 : undef;  # LSP 0-indexed → PPI 1-indexed
    my ($best, $best_span, $best_any);

    for my $sym (@$symbols) {
        my $kind = $sym->{kind} // '';
        next unless $kind eq 'variable' || $kind eq 'parameter';
        next unless ($sym->{name} // '') eq $var_name;
        next unless $sym->{type};

        my $is_any = $sym->{type} eq 'Any';

        # Scoped symbol: check if hover line falls within scope
        if ($ppi_line && $sym->{scope_start} && $sym->{scope_end}) {
            if ($ppi_line >= $sym->{scope_start} && $ppi_line <= $sym->{scope_end}) {
                my $span = $sym->{scope_end} - $sym->{scope_start};
                if ($is_any) {
                    $best_any //= $sym->{type};
                } elsif (!defined $best_span || $span < $best_span) {
                    $best = $sym->{type};
                    $best_span = $span;
                }
                next;
            }
            next;  # out of scope — skip
        }

        # Non-scoped symbol
        if ($is_any) {
            $best_any //= $sym->{type};
        } else {
            $best //= $sym->{type};
        }
    }

    $best // $best_any;
}

# ── Accessor Hover Resolution ───────────────────

# Resolve struct field type for accessor hover.
# Supports: $var->field, $var->f1->f2, func()->field, Pkg::func()->field
# Returns a symbol hashref with kind => 'field' or undef.
sub resolve_accessor_hover ($self, $line, $col, $word) {
    my $lines = $self->{lines};
    return undef unless $line < @$lines;

    my $result   = $self->{result} // return undef;
    my $registry = $result->{registry} // return undef;

    # Find the end of the word under cursor (skip past $col to end of \w chars)
    my $full_line = $lines->[$line];
    my $word_end = $col;
    $word_end++ while $word_end < length($full_line) && substr($full_line, $word_end, 1) =~ /\w/;
    my $text = substr($full_line, 0, $word_end);

    # Must contain -> to be an accessor
    return undef unless $text =~ /->/;

    # Extract the accessor chain suffix: ->field1->field2...
    return undef unless $text =~ /((?:\s*->\s*\w+)+)\s*$/;
    my $chain_str = $1;
    my @chain = ($chain_str =~ /->\s*(\w+)/g);
    return undef unless @chain && $chain[-1] eq $word;

    my $prefix = substr($text, 0, length($text) - length($chain_str));

    # Try resolving the head type from prefix
    my $type_str;

    # Pattern 1: $var->...
    if ($prefix =~ /(\$\w+)\s*$/) {
        $type_str = $self->resolve_var_type($1, $line);
    }

    # Pattern 2: func(...)->... or Pkg::func(...)->...
    if (!$type_str && $prefix =~ /\)\s*$/) {
        $type_str = $self->resolve_call_return_type($prefix, $registry);
    }

    return undef unless $type_str;
    my $type = eval { Typist::Parser->parse($type_str) } // return undef;

    # Check if this accessor is narrowed by defined() guard
    my $narrowed = 0;
    my $ppi_line = $line + 1;  # LSP 0-indexed → PPI 1-indexed
    for my $na (($result->{narrowed_accessors} // [])->@*) {
        next unless $na->{var_name} eq ($prefix =~ /(\$\w+)\s*$/ ? $1 : '');
        next unless $ppi_line >= $na->{scope_start} && $ppi_line <= $na->{scope_end};
        # Compare chains: narrowed chain must match the accessor chain
        my $nc = $na->{chain};
        next unless @$nc == @chain;
        my $match = 1;
        for my $i (0 .. $#chain) {
            if ($nc->[$i] ne $chain[$i]) { $match = 0; last }
        }
        if ($match) { $narrowed = 1; last }
    }

    $self->walk_accessor_chain($type, \@chain, $word, $registry, $narrowed);
}

# ── Accessor Chain Walking ──────────────────────

# Walk an accessor chain, resolving struct fields at each step.
sub walk_accessor_chain ($self, $type, $chain, $word, $registry, $narrowed = 0) {
    for my $i (0 .. $#$chain) {
        my $field = $chain->[$i];

        # Resolve alias → concrete type (newtype, struct, or datatype)
        my $resolved = $self->resolve_type_deep($type, $registry) // return undef;

        # EffectScope: method calls dispatch to effect operations
        if ($resolved->to_string =~ /\AEffectScope\[(\w+)/) {
            my $effect_name = $1;
            return undef unless $registry;
            my $eff = $registry->lookup_effect($effect_name) // return undef;
            if ($i == $#$chain) {
                my $op_type = $eff->get_op_type($field);
                my $returns = $op_type && $op_type->is_func
                    ? $op_type->returns->to_string : 'Any';
                return sym_method(
                    name        => $field,
                    struct_name => "EffectScope[$effect_name]",
                    returns     => $returns,
                );
            }
            return undef;  # EffectScope ops don't chain
        }

        # Newtype: no instance methods
        if ($resolved->is_newtype) {
            return undef;
        }

        # Struct: field accessor
        my $struct = $resolved->is_struct ? $resolved
                   : $self->resolve_to_struct($resolved, $registry) // return undef;

        my %req = $struct->required_fields;
        my %opt = $struct->optional_fields;

        if (exists $req{$field}) {
            $type = $req{$field};
            if ($i == $#$chain) {
                # When narrowed by defined() guard, strip Undef from Union types
                my $display_type = $type;
                if ($narrowed && $type->is_union) {
                    my @non_undef = grep { !($_->is_atom && $_->name eq 'Undef') } $type->members;
                    if (@non_undef && @non_undef < scalar($type->members)) {
                        $display_type = @non_undef == 1 ? $non_undef[0]
                            : Typist::Type::Union->new(@non_undef);
                    }
                }
                return sym_field(
                    name        => $field,
                    type        => $display_type->to_string,
                    struct_name => $struct->name,
                    optional    => 0,
                    ($narrowed ? (narrowed => 1) : ()),
                );
            }
        } elsif (exists $opt{$field}) {
            $type = $opt{$field};
            if ($i == $#$chain) {
                # When narrowed (e.g. defined() guard), strip Undef from the type
                my $display_type = $type;
                if ($narrowed && $type->is_union) {
                    my @non_undef = grep { !($_->is_atom && $_->name eq 'Undef') } $type->members;
                    if (@non_undef && @non_undef < scalar($type->members)) {
                        $display_type = @non_undef == 1 ? $non_undef[0]
                            : Typist::Type::Union->new(@non_undef);
                    }
                }
                return sym_field(
                    name        => $field,
                    type        => $display_type->to_string,
                    struct_name => $struct->name,
                    optional    => $narrowed ? 0 : 1,
                    ($narrowed ? (narrowed => 1) : ()),
                );
            }
        } else {
            return undef;
        }
    }
    undef;
}

# ── Type Resolution Helpers ─────────────────────

# Resolve a type through aliases to its concrete form (newtype, struct, datatype, etc.).
sub resolve_type_deep ($self, $type, $registry) {
    return $type if $type->is_newtype || $type->is_struct;
    if ($type->is_alias) {
        my $resolved = eval { $registry->lookup_type($type->alias_name) };
        return $resolved if $resolved;
    }
    $type;
}

# Resolve a type to a Struct via alias/registry lookup.
sub resolve_to_struct ($self, $type, $registry) {
    return $type if $type->is_struct;
    if ($type->is_alias) {
        my $resolved = eval { $registry->lookup_type($type->alias_name) };
        return $resolved if $resolved && $resolved->is_struct;
    }
    undef;
}

# ── Function Return Type Resolution ─────────────

# Resolve the return type of a function call from a text prefix ending with ')'.
# Handles: func(...), Pkg::func(...), nested parens.
sub resolve_call_return_type ($self, $prefix, $registry) {
    # Find the matching '(' by scanning backwards from the last ')'
    my $depth = 0;
    my $paren_pos;
    for my $i (reverse 0 .. length($prefix) - 1) {
        my $ch = substr($prefix, $i, 1);
        if ($ch eq ')') {
            $depth++;
        } elsif ($ch eq '(') {
            $depth--;
            if ($depth == 0) {
                $paren_pos = $i;
                last;
            }
        }
    }
    return undef unless defined $paren_pos;

    # Extract function name before the '('
    my $before = substr($prefix, 0, $paren_pos);
    return undef unless $before =~ /((?:\w+::)*\w+)\s*$/;
    my $func_name = $1;

    $self->resolve_func_return_type($func_name, $registry);
}

# Look up function return type from local symbols and registry.
sub resolve_func_return_type ($self, $func_name, $registry) {
    my $result = $self->{result} // return undef;

    # Local symbols
    for my $sym (@{$result->{symbols} // []}) {
        next unless ($sym->{kind} // '') eq 'function';
        next unless ($sym->{name} // '') eq $func_name;
        return $sym->{returns_expr} if $sym->{returns_expr};
    }

    return undef unless $registry;

    # Qualified name: Pkg::func
    if ($func_name =~ /\A(.+)::(\w+)\z/) {
        if (my $sig = $registry->lookup_function($1, $2)) {
            return _sig_returns_str($sig);
        }
    }

    # Current package
    my $pkg = $result->{extracted}{package} // 'main';
    if (my $sig = $registry->lookup_function($pkg, $func_name)) {
        return _sig_returns_str($sig);
    }

    # Search all packages (Exporter-imported constructors, etc.)
    if (my $sig = $registry->search_function_by_name($func_name)) {
        return _sig_returns_str($sig);
    }

    undef;
}

sub _sig_returns_str ($sig) {
    if ($sig->{returns}) {
        return ref $sig->{returns} ? $sig->{returns}->to_string : $sig->{returns};
    }
    $sig->{returns_expr};
}

1;

=head1 NAME

Typist::LSP::Document::Resolver - Type resolution for accessor chains and symbols

=head1 SYNOPSIS

    use Typist::LSP::Document::Resolver;

    my $resolver = Typist::LSP::Document::Resolver->new(
        result => $analysis_result,
        lines  => $line_array,
    );

    my $sym = $resolver->resolve_accessor_hover($line, $col, $word);
    my $type_str = $resolver->resolve_var_type('$var', $line);

=head1 DESCRIPTION

Encapsulates type resolution logic for LSP features (hover, completion,
go-to-definition). Resolves accessor chains through struct fields,
newtypes, and aliases. All resolution is based on the analysis result
and the document text — no mutable state.

=head1 SEE ALSO

L<Typist::LSP::Document>, L<Typist::Static::SymbolInfo>

=cut
