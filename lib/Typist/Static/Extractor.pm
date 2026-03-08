package Typist::Static::Extractor;
use v5.40;

our $VERSION = '0.01';

use PPI;
use Typist::Parser;
use Typist::Prelude;

# ── Public API ───────────────────────────────────

# Extract type annotations from Perl source text.
# Returns a structured hash of aliases, variables, functions, and package name.
sub extract ($class, $source) {
    my $doc = PPI::Document->new(\$source)
        or die "Typist::Static::Extractor: failed to parse source";

    my $result = +{
        aliases        => +{},
        variables      => [],
        functions      => +{},
        newtypes       => +{},
        datatypes      => +{},
        effects        => +{},
        structs        => +{},
        typeclasses    => +{},
        instances      => [],
        declares       => +{},
        loop_variables => [],
        use_modules    => [],
        special_words  => +{},
        assignment_ops => [],
        call_words     => [],
        word_tokens    => [],
        package        => 'main',
        ppi_doc        => $doc,
    };

    # ── Single-pass PPI traversal ────────────────
    # Classify all statements by type and keyword in one tree walk,
    # replacing 12+ separate find() calls with a single traversal.
    my $all_stmts = $doc->find('PPI::Statement') || [];
    my (@var_stmts, @sub_stmts, @compound_stmts);
    my %kw_stmts;

    for my $stmt (@$all_stmts) {
        if ($stmt->isa('PPI::Statement::Package')) {
            $result->{package} = $stmt->namespace;
        } elsif ($stmt->isa('PPI::Statement::Include')
                 && ($stmt->type // '') eq 'use'
                 && $stmt->module) {
            push @{$result->{use_modules}}, $stmt->module;
        } elsif ($stmt->isa('PPI::Statement::Sub')
                 && !$stmt->isa('PPI::Statement::Scheduled')) {
            push @sub_stmts, $stmt;
        } elsif ($stmt->isa('PPI::Statement::Variable')) {
            push @var_stmts, $stmt;
        } elsif ($stmt->isa('PPI::Statement::Compound')) {
            push @compound_stmts, $stmt;
        } else {
            my $first = $stmt->schild(0);
            if ($first && $first->isa('PPI::Token::Word')) {
                push @{$kw_stmts{$first->content}}, $stmt;
            }
        }
    }

    $class->_extract_typedefs($kw_stmts{typedef}   // [], $result);
    $class->_extract_newtypes($kw_stmts{newtype}   // [], $result);
    $class->_extract_datatypes($kw_stmts{datatype} // [], $result);
    $class->_extract_enums($kw_stmts{enum}         // [], $result);
    $class->_extract_structs($kw_stmts{struct}     // [], $result);
    $class->_extract_effects($kw_stmts{effect}     // [], $result);
    $class->_extract_typeclasses($kw_stmts{typeclass} // [], $result);
    $class->_extract_instances($kw_stmts{instance} // [], $result);
    $class->_extract_declares($kw_stmts{declare}   // [], $result);
    $class->_extract_variables(\@var_stmts, $result);
    $class->_extract_functions(\@sub_stmts, $result);
    $class->_extract_loop_variables(\@compound_stmts, $result);
    $class->_collect_special_words($doc, $result);
    $class->_collect_assignment_ops(\@$all_stmts, $result);

    $result->{ignore_lines} = $class->_collect_ignore_lines($doc);

    $result;
}

sub _collect_special_words ($class, $doc, $result) {
    my %wanted = map { $_ => 1 } qw(match handle map grep sort);
    my %found;
    my @call_words;
    my %known_locals = map { $_ => 1 } keys $result->{functions}->%*;
    my %known_declares = map {
        my $name = $_;
        $name =~ s/\A.+:://;
        $name => 1;
    } keys $result->{declares}->%*;
    my %known_builtins = map { $_ => 1 } Typist::Prelude->builtin_names;
    my $words = $doc->find('PPI::Token::Word') || [];
    $result->{word_tokens} = $words;
    for my $word (@$words) {
        my $name = $word->content;
        next unless $wanted{$name};
        push @{$found{$name} //= []}, $word;
    }
    for my $word (@$words) {
        my $name = $word->content;
        my $prev = $word->sprevious_sibling;
        if ($prev && ref($prev) && $prev->isa('PPI::Token::Operator') && $prev->content eq '->') {
            push @call_words, $word;
            next;
        }

        my $next = $word->snext_sibling // next;
        next unless ref($next) && $next->isa('PPI::Structure::List');
        next unless $known_locals{$name}
            || $known_declares{$name}
            || $known_builtins{$name}
            || $wanted{$name}
            || $name =~ /::/
            || $name =~ /\A[A-Z]\w*\z/;
        push @call_words, $word;
    }
    $result->{special_words} = \%found;
    $result->{call_words} = \@call_words;
}

sub _collect_assignment_ops ($class, $stmts, $result) {
    my @ops;
    for my $stmt (@$stmts) {
        next if $stmt->isa('PPI::Statement::Variable');
        for my $child ($stmt->schildren) {
            next unless $child->isa('PPI::Token::Operator');
            next unless $child->content eq '=';
            push @ops, $child;
        }
    }
    $result->{assignment_ops} = \@ops;
}

# ── typedef Extraction ──────────────────────────

sub _extract_typedefs ($class, $stmts, $result) {
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        # typedef Name => 'Expr'
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'typedef';

        my $name = $children[1]->content;
        # Skip => operator
        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        my $expr = $class->_collect_rhs_expr(@children[3 .. $#children]);
        next unless defined $expr;

        $result->{aliases}{$name} = +{
            expr => $expr,
            line => $stmt->line_number,
            col  => $stmt->column_number,
        };
    }
}

# ── Newtype Extraction ─────────────────────────

sub _extract_newtypes ($class, $stmts, $result) {
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        # newtype Name => 'Expr'
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'newtype';

        my $name = $children[1]->content;
        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        my $expr = $class->_collect_rhs_expr(@children[3 .. $#children]);
        next unless defined $expr;

        $result->{newtypes}{$name} = +{
            inner_expr => $expr,
            line       => $stmt->line_number,
            col        => $stmt->column_number,
        };
    }
}

# ── Datatype Extraction ────────────────────────

sub _extract_datatypes ($class, $stmts, $result) {
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        # datatype Name => Tag1 => '(Type, ...)', Tag2 => '(Type)', ...
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'datatype';

        # Name may be a bare word or quoted string (for parameterized: 'Option[T]')
        my $name_tok = $children[1];
        my $name_raw = $name_tok->isa('PPI::Token::Quote')
            ? $name_tok->string
            : $name_tok->content;
        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        # Parse name and type parameters
        my ($base_name, @raw);
        ($base_name, @raw) = Typist::Parser->parse_parameterized_name($name_raw);
        my @type_params = map { s/\s//gr } @raw;

        # Parse variant pairs from remaining children.
        # Parenthesised form: datatype Name => (Tag => '()', ...)
        # produces a PPI::Structure::List wrapping the pairs.
        my @rest = @children[3 .. $#children];
        if (@rest && $rest[0]->isa('PPI::Structure::List')) {
            my $expr = $rest[0]->schild(0);
            @rest = $expr ? $expr->schildren : ();
        }
        my %variants;
        my $i = 0;
        while ($i < @rest) {
            last if $rest[$i]->isa('PPI::Token::Structure')
                 && $rest[$i]->content eq ';';

            # Skip commas
            if ($rest[$i]->isa('PPI::Token::Operator')
                && $rest[$i]->content eq ',')
            {
                $i++;
                next;
            }

            # Expect a tag name (Word)
            last unless $rest[$i]->isa('PPI::Token::Word');
            my $tag = $rest[$i]->content;
            $i++;

            # Expect =>
            last unless $i < @rest
                     && $rest[$i]->isa('PPI::Token::Operator')
                     && $rest[$i]->content eq '=>';
            $i++;

            # Expect a spec (quoted string)
            last unless $i < @rest;
            my $spec_tok = $rest[$i];
            my $spec = $spec_tok->isa('PPI::Token::Quote')
                ? $spec_tok->string
                : $spec_tok->content;
            $variants{$tag} = $spec;
            $i++;
        }

        $result->{datatypes}{$base_name} = +{
            variants    => \%variants,
            type_params => \@type_params,
            line        => $stmt->line_number,
            col         => $stmt->column_number,
        };
    }
}

# ── Enum Extraction ────────────────────────────
#
# enum Name => qw(Tag1 Tag2 Tag3);
# Stored as datatypes with all-nullary variants.

sub _extract_enums ($class, $stmts, $result) {
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'enum';

        my $name = $children[1]->content;
        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        # Collect tag names from remaining tokens (Words, skip commas/semicolons)
        my %variants;
        for my $i (3 .. $#children) {
            my $tok = $children[$i];
            next if $tok->isa('PPI::Token::Operator') && $tok->content eq ',';
            last if $tok->isa('PPI::Token::Structure') && $tok->content eq ';';
            if ($tok->isa('PPI::Token::Word') && $tok->content ne 'qw') {
                $variants{$tok->content} = '';
            }
            # Handle qw(...) list
            if ($tok->isa('PPI::Token::QuoteLike::Words')) {
                $variants{$_} = '' for $tok->literal;
            }
        }

        $result->{datatypes}{$name} = +{
            variants    => \%variants,
            type_params => [],
            line        => $stmt->line_number,
            col         => $stmt->column_number,
        };
    }
}

# ── Struct Extraction ─────────────────────────
#
# struct Name => (field => 'Type', optional(field2 => 'Type'), ...);

sub _extract_structs ($class, $stmts, $result) {
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'struct';

        my $name_tok = $children[1];
        my $name_raw = $name_tok->isa('PPI::Token::Quote')
            ? $name_tok->string
            : $name_tok->content;
        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        # Parse name and type parameters (e.g., 'Rect[T]', 'NumBox[T: Num]')
        my ($base_name, @type_params, @raw_specs);
        ($base_name, @raw_specs) = Typist::Parser->parse_parameterized_name($name_raw);
        @type_params = map { /\A(\w+)/ ? $1 : $_ } @raw_specs;

        # Extract field definitions from the List structure
        my (%fields, @optional_fields);
        for my $child (@children[3 .. $#children]) {
            next unless $child->isa('PPI::Structure::List');
            $class->_extract_struct_fields($child, \%fields, \@optional_fields);
            last;
        }

        $result->{structs}{$base_name} = +{
            fields           => \%fields,
            optional_fields  => \@optional_fields,
            type_params      => \@type_params,
            type_param_specs => \@raw_specs,
            line             => $stmt->line_number,
            col              => $stmt->column_number,
        };
    }
}

sub _extract_struct_fields ($class, $list, $fields, $optional_fields) {
    for my $child ($list->schildren) {
        next unless $child->isa('PPI::Statement')
                 || $child->isa('PPI::Statement::Expression');
        my @sc = $child->schildren;
        my $i = 0;

        while ($i <= $#sc) {
            # Skip commas and semicolons
            if ($sc[$i]->isa('PPI::Token::Operator') && $sc[$i]->content eq ',') {
                $i++;
                next;
            }
            last if $sc[$i]->isa('PPI::Token::Structure') && $sc[$i]->content eq ';';

            # Check for optional(field => 'Type')
            if ($sc[$i]->isa('PPI::Token::Word') && $sc[$i]->content eq 'optional'
                && $i + 1 <= $#sc && $sc[$i + 1]->isa('PPI::Structure::List'))
            {
                my $list_content = $class->_list_content($sc[$i + 1]);
                if (defined $list_content && $list_content =~ /\A(\w+)\s*(?:=>|,)\s*(.*)\z/s) {
                    my ($fname, $ftype) = ($1, $2);
                    $ftype =~ s/\A'(.*)'\z/$1/s;   # strip quotes
                    $ftype =~ s/\A"(.*)"\z/$1/s;
                    $fields->{$fname} = length($ftype) ? $ftype : 'Any';
                    push @$optional_fields, $fname;
                }
                $i += 2;
                next;
            }

            # Expect field name (Word)
            last unless $sc[$i]->isa('PPI::Token::Word');
            my $field_name = $sc[$i]->content;
            $i++;

            # Expect =>
            last unless $i <= $#sc
                     && $sc[$i]->isa('PPI::Token::Operator')
                     && $sc[$i]->content eq '=>';
            $i++;
            last unless $i <= $#sc;

            # Collect type expression tokens until comma or end
            {
                my @type_tokens;
                while ($i <= $#sc) {
                    last if $sc[$i]->isa('PPI::Token::Operator') && $sc[$i]->content eq ',';
                    last if $sc[$i]->isa('PPI::Token::Structure') && $sc[$i]->content eq ';';
                    push @type_tokens, $sc[$i];
                    $i++;
                }
                if (@type_tokens == 1 && $type_tokens[0]->isa('PPI::Token::Quote')) {
                    $fields->{$field_name} = $type_tokens[0]->string;
                } elsif (@type_tokens) {
                    $fields->{$field_name} = join('', map { $_->content } @type_tokens);
                }
            }
        }
    }
}

# ── Effect Extraction ──────────────────────────
#
# Supports two syntaxes:
#   Protocol: effect Name => qw/States.../ => +{ op => protocol('sig', 'From -> To'), ... }
#   Plain:    effect Name => +{ op => 'sig', ... }  (protocol-less)
#
# Operations with protocol() values carry inline protocol transitions.
# String values are plain signatures (no protocol).

sub _extract_effects ($class, $stmts, $result) {
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        next unless @children >= 3;

        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'effect';

        my $name = $children[1]->isa('PPI::Token::Quote')
            ? $children[1]->string
            : $children[1]->content;

        # Detect states: effect Name => qw/States.../ => +{...}
        # States appear as QuoteLike::Words tokens between the name and the ops block
        my @states;
        my $scan_start = 2;
        for my $ci (2 .. $#children) {
            my $child = $children[$ci];
            if ($child->isa('PPI::Token::QuoteLike::Words')) {
                push @states, $child->literal;
                $scan_start = $ci + 1;
            }
            last if $child->isa('PPI::Structure::Constructor')
                 || $child->isa('PPI::Structure::Block');
        }

        # Find the operations block (Constructor/Block)
        my (@op_names, %op_sigs, %transitions, %op_map);
        for my $ci ($scan_start .. $#children) {
            my $child = $children[$ci];
            next unless $child->isa('PPI::Structure::Constructor')
                     || $child->isa('PPI::Structure::Block')
                     || $child->isa('PPI::Structure::List');
            for my $expr ($child->schildren) {
                next unless $expr->isa('PPI::Statement') || $expr->isa('PPI::Statement::Expression');
                my @sc = $expr->schildren;
                my $i = 0;
                while ($i <= $#sc) {
                    # Skip commas
                    if ($sc[$i]->isa('PPI::Token::Operator') && $sc[$i]->content eq ',') {
                        $i++;
                        next;
                    }
                    last if $sc[$i]->isa('PPI::Token::Structure') && $sc[$i]->content eq ';';

                    # Expect op name (Word) => value
                    last unless $sc[$i]->isa('PPI::Token::Word');
                    my $op_name = $sc[$i]->content;
                    $i++;
                    last unless $i <= $#sc
                             && $sc[$i]->isa('PPI::Token::Operator')
                             && $sc[$i]->content eq '=>';
                    $i++;
                    last unless $i <= $#sc;

                    # Value: Quote (string) or protocol('sig', 'transition') call
                    if ($sc[$i]->isa('PPI::Token::Quote')) {
                        push @op_names, $op_name;
                        $op_sigs{$op_name} = $sc[$i]->string;
                        $i++;
                    } elsif ($sc[$i]->isa('PPI::Token::Word') && $sc[$i]->content eq 'protocol'
                          && $i + 1 <= $#sc && $sc[$i + 1]->isa('PPI::Structure::List'))
                    {
                        my ($sig, $from, $to) = $class->_extract_protocol_call($sc[$i + 1]);
                        if (defined $sig) {
                            push @op_names, $op_name;
                            $op_sigs{$op_name} = $sig;
                            if (defined $from && defined $to) {
                                $op_map{$op_name} = { from => $from, to => $to };
                                for my $f (@$from) {
                                    $transitions{$f}{$op_name} = $to->[0];
                                }
                            }
                        }
                        $i += 2; # skip Word('protocol') + List(...)
                    } else {
                        $i++;
                    }
                }
            }
            last;
        }

        $result->{effects}{$name} = +{
            op_names   => \@op_names,
            operations => \%op_sigs,
            protocol   => (%transitions ? \%transitions : undef),
            op_map     => (%op_map ? \%op_map : undef),
            states     => (@states ? \@states : undef),
            line       => $stmt->line_number,
            col        => $stmt->column_number,
        };
    }
}

# Extract (sig_string, from, to) from a protocol('sig', 'transition') call's List node.
# Returns ($sig, $from, $to) or ($sig, undef, undef) if transition parse fails.
sub _extract_protocol_call ($class, $list) {
    my ($sig, $from, $to);
    my @quotes;

    for my $le ($list->schildren) {
        my @lc = ref($le) && $le->can('schildren') ? $le->schildren : ($le);
        for my $tok (@lc) {
            push @quotes, $tok->string if $tok->isa('PPI::Token::Quote');
        }
    }

    # First quote = sig, second quote = transition
    $sig = $quotes[0] if @quotes >= 1;
    if (@quotes >= 2) {
        my $trans = $quotes[1];
        if ($trans =~ /^\s*(.+?)\s*->\s*(.+?)\s*$/) {
            $from = [sort map { s/\s+//gr } split(/\s*\|\s*/, $1)];
            $to   = [sort map { s/\s+//gr } split(/\s*\|\s*/, $2)];
        }
    }

    ($sig, $from, $to);
}

# ── TypeClass Extraction ───────────────────────

sub _extract_typeclasses ($class, $stmts, $result) {
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        next unless @children >= 3;

        # typeclass Name => VarSpec, +{ method => sig, ... }
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'typeclass';

        my $name_tok = $children[1];
        my $name = $name_tok->isa('PPI::Token::Quote')
            ? $name_tok->string
            : $name_tok->content;

        # Extract var_spec from [3] (after => operator)
        my $var_spec;
        if (@children >= 4
            && $children[2]->isa('PPI::Token::Operator')
            && $children[2]->content eq '=>')
        {
            my $vs_tok = $children[3];
            $var_spec = $vs_tok->isa('PPI::Token::Quote')
                ? $vs_tok->string
                : $vs_tok->content;
        }

        # Extract method names and signatures from the structure
        my (@method_names, %method_sigs);
        for my $child (@children) {
            next unless $child->isa('PPI::Structure::Constructor')
                     || $child->isa('PPI::Structure::Block')
                     || $child->isa('PPI::Structure::List');
            for my $expr ($child->schildren) {
                next unless $expr->isa('PPI::Statement') || $expr->isa('PPI::Statement::Expression');
                my @sc = $expr->schildren;
                for my $i (0 .. $#sc - 1) {
                    if ($sc[$i]->isa('PPI::Token::Word')
                        && $sc[$i + 1]->isa('PPI::Token::Operator')
                        && $sc[$i + 1]->content eq '=>')
                    {
                        my $mname = $sc[$i]->content;
                        push @method_names, $mname;
                        # Capture signature from the following QuotedString
                        if ($i + 2 <= $#sc && $sc[$i + 2]->isa('PPI::Token::Quote')) {
                            $method_sigs{$mname} = $sc[$i + 2]->string;
                        }
                    }
                }
            }
            last;
        }

        $result->{typeclasses}{$name} = +{
            var_spec     => $var_spec,
            method_names => \@method_names,
            methods      => \%method_sigs,
            line         => $stmt->line_number,
            col          => $stmt->column_number,
        };
    }
}

# ── Instance Extraction ────────────────────────
#
# instance ClassName => TypeExpr, +{ method => sub ... }
# instance ClassName => 'TypeExpr', +{ method => sub ... }

sub _extract_instances ($class, $stmts, $result) {
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'instance';

        # Class name: bare Word or quoted string
        my $class_tok = $children[1];
        my $class_name = $class_tok->isa('PPI::Token::Quote')
            ? $class_tok->string
            : $class_tok->content;

        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        # Type expression: Word or Quote
        my $type_tok = $children[3];
        my $type_expr;
        if ($type_tok->isa('PPI::Token::Quote')) {
            $type_expr = $type_tok->string;
        } elsif ($type_tok->isa('PPI::Token::Word')) {
            $type_expr = $type_tok->content;
        } else {
            next;
        }

        # Extract method names from the methods hashref block
        my @method_names;
        for my $child (@children[4 .. $#children]) {
            next unless $child->isa('PPI::Structure::Constructor')
                     || $child->isa('PPI::Structure::Block')
                     || $child->isa('PPI::Structure::List');
            for my $expr ($child->schildren) {
                next unless $expr->isa('PPI::Statement') || $expr->isa('PPI::Statement::Expression');
                my @sc = $expr->schildren;
                for my $i (0 .. $#sc - 1) {
                    if ($sc[$i]->isa('PPI::Token::Word')
                        && $sc[$i + 1]->isa('PPI::Token::Operator')
                        && $sc[$i + 1]->content eq '=>')
                    {
                        push @method_names, $sc[$i]->content;
                    }
                }
            }
            last;
        }

        push $result->{instances}->@*, +{
            class_name   => $class_name,
            type_expr    => $type_expr,
            method_names => \@method_names,
            line         => $stmt->line_number,
            col          => $stmt->column_number,
        };
    }
}

# ── Declare Extraction ─────────────────────────

sub _extract_declares ($class, $stmts, $result) {
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        next unless @children >= 4;

        # declare NAME => 'type_expr'
        # declare 'Pkg::Name' => 'type_expr'
        next unless $children[0]->isa('PPI::Token::Word')
                 && $children[0]->content eq 'declare';

        # Name: bare Word or quoted string
        my $name_tok = $children[1];
        my $name;
        if ($name_tok->isa('PPI::Token::Quote')) {
            $name = $name_tok->string;
        } elsif ($name_tok->isa('PPI::Token::Word')) {
            $name = $name_tok->content;
        } else {
            next;
        }

        # => operator
        next unless $children[2]->isa('PPI::Token::Operator')
                 && $children[2]->content eq '=>';

        my $type_expr = $class->_collect_rhs_expr(@children[3 .. $#children]);
        next unless defined $type_expr;

        # Determine package and function name
        my ($pkg, $fn_name);
        if ($name =~ /\A(.+)::(\w+)\z/) {
            ($pkg, $fn_name) = ($1, $2);
        } else {
            ($pkg, $fn_name) = ('CORE', $name);
        }

        $result->{declares}{$name} = +{
            name      => $name,
            package   => $pkg,
            func_name => $fn_name,
            type_expr => $type_expr,
            line      => $stmt->line_number,
            col       => $stmt->column_number,
        };
    }
}

# ── Variable Extraction ─────────────────────────

# PPI does not recognize variable attributes as PPI::Token::Attribute.
# Instead, `my $x :sig(Int)` is parsed as:
#   Symbol($x) Operator(:) Word(sig) List( Expression(Word(Int)) )
# We detect this pattern by scanning PPI::Statement::Variable children.
sub _extract_variables ($class, $stmts, $result) {
    my %typed_vars;

    # First pass: annotated variables (:sig(...))
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;

        # Find the variable symbol
        my $var_name;
        for my $i (0 .. $#children) {
            my $child = $children[$i];

            if ($child->isa('PPI::Token::Symbol')) {
                $var_name = $child->content;
                next;
            }

            # Look for : operator followed by Word('Type') followed by List
            next unless $child->isa('PPI::Token::Operator')
                     && $child->content eq ':'
                     && $var_name;

            my $next = $children[$i + 1] // next;
            next unless $next->isa('PPI::Token::Word')
                     && $next->content eq 'sig';

            my $list = $children[$i + 2] // next;
            next unless $list->isa('PPI::Structure::List');

            # Extract the type expression from the list content
            my $type_expr = $class->_list_content($list);
            next unless $type_expr;

            # Find the initializer node (RHS of '=')
            my $init_node;
            for my $j ($i + 3 .. $#children) {
                if ($children[$j]->isa('PPI::Token::Operator') && $children[$j]->content eq '=') {
                    $init_node = $children[$j + 1] if $j + 1 <= $#children;
                    last;
                }
            }

            $typed_vars{$var_name} = 1;
            push $result->{variables}->@*, +{
                name      => $var_name,
                type_expr => $type_expr,
                line      => $next->line_number,
                col       => $next->column_number,
                init_node => $init_node,
            };
        }
    }

    # Second pass: unannotated variables with initializer (for flow typing)
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        my ($var_name, $var_sym, $init_node);
        my @list_syms;

        for my $i (0 .. $#children) {
            # List pattern: my ($a, $b) = ...
            if ($children[$i]->isa('PPI::Structure::List') && !$var_name && !@list_syms) {
                my $expr = $children[$i]->find_first('PPI::Statement::Expression')
                        || $children[$i]->find_first('PPI::Statement');
                if ($expr) {
                    @list_syms = grep { $_->isa('PPI::Token::Symbol') } $expr->schildren;
                }
            }
            if ($children[$i]->isa('PPI::Token::Symbol') && !$var_name && !@list_syms) {
                $var_name = $children[$i]->content;
                $var_sym  = $children[$i];
            }
            if ($children[$i]->isa('PPI::Token::Operator') && $children[$i]->content eq '=') {
                $init_node = $children[$i + 1] if $i + 1 <= $#children;
                last;
            }
        }

        # List assignment: my ($a, $b) = expr
        if (@list_syms && $init_node) {
            for my $pos (0 .. $#list_syms) {
                my $sym = $list_syms[$pos];
                next if $typed_vars{$sym->content};
                $typed_vars{$sym->content} = 1;
                push $result->{variables}->@*, +{
                    name          => $sym->content,
                    type_expr     => undef,
                    line          => $sym->line_number,
                    col           => $sym->column_number,
                    init_node     => $init_node,
                    list_position => $pos,
                    list_count    => scalar @list_syms,
                };
            }
            next;
        }

        next unless $var_name && $init_node;
        next if $typed_vars{$var_name};

        $typed_vars{$var_name} = 1;
        push $result->{variables}->@*, +{
            name      => $var_name,
            type_expr => undef,
            line      => $var_sym->line_number,
            col       => $var_sym->column_number,
            init_node => $init_node,
        };
    }

    # Third pass: unannotated variables without initializer → captured for Any display
    for my $stmt (@$stmts) {
        my @children = $stmt->schildren;
        for my $child (@children) {
            next unless $child->isa('PPI::Token::Symbol');
            my $var_name = $child->content;
            next if $typed_vars{$var_name};

            $typed_vars{$var_name} = 1;
            push $result->{variables}->@*, +{
                name      => $var_name,
                type_expr => undef,
                line      => $child->line_number,
                col       => $child->column_number,
                init_node => undef,
            };
        }
    }
}

# ── Function Extraction ─────────────────────────

sub _extract_functions ($class, $subs, $result) {
    for my $sub_stmt (@$subs) {
        my $name = $sub_stmt->name // next;

        # Name token column (schild(1) = function name after 'sub')
        my $name_tok = $sub_stmt->schild(1);
        my $name_col = ($name_tok && $name_tok->isa('PPI::Token::Word'))
            ? $name_tok->column_number
            : $sub_stmt->column_number + 4;  # fallback: "sub " = 4 chars

        # Detect method: first parameter is $self or $class
        my $param_names = $class->_extract_sig_params($sub_stmt);
        my $default_count = $class->_count_sig_defaults($sub_stmt);
        my ($is_method, $method_kind) = (0, undef);
        if (@$param_names && $param_names->[0] eq '$self') {
            ($is_method, $method_kind) = (1, 'instance');
        }
        elsif (@$param_names && $param_names->[0] eq '$class') {
            ($is_method, $method_kind) = (1, 'class');
        }

        my @attrs;
        for my $child ($sub_stmt->schildren) {
            last if $child->isa('PPI::Structure::Block');
            push @attrs, $child if $child->isa('PPI::Token::Attribute');
        }

        if (@attrs) {
            # Look for :sig(...) annotation
            my $type_ann;
            for my $attr (@attrs) {
                my $content = $attr->content;
                if ($content =~ /\Asig\((.+)\)\z/s) {
                    $type_ann = $1;
                    last;
                }
            }

            if ($type_ann) {
                my $ann = eval {
                    require Typist::Parser;
                    Typist::Parser->parse_annotation($type_ann);
                };
                next if $@;

                my $type = $ann->{type};
                my (@params_expr, $returns_expr, $eff_expr);

                my $variadic = 0;
                if ($type->is_func) {
                    @params_expr = map { $_->to_string } $type->params;
                    $returns_expr = $type->returns->to_string;
                    $eff_expr = $type->effects
                        ? $type->effects->to_string : undef;
                    $variadic = $type->variadic;
                } else {
                    $returns_expr = $type->to_string;
                }

                my $block = $sub_stmt->block;
                my ($last_stmt, $last_first) = $class->_last_stmt_info($block);
                my $block_words = $class->_collect_block_words($block);
                $result->{functions}{$name} = +{
                    params_expr   => \@params_expr,
                    returns_expr  => $returns_expr,
                    generics      => $ann->{generics_raw},
                    eff_expr      => $eff_expr,
                    variadic      => $variadic,
                    default_count => $default_count,
                    param_names   => $param_names,
                    is_method     => $is_method,
                    method_kind   => $method_kind,
                    line          => $sub_stmt->line_number,
                    end_line      => $class->_end_line($sub_stmt),
                    col           => $sub_stmt->column_number,
                    name_col      => $name_col,
                    block         => $block,
                    block_words   => $block_words,
                    return_words  => $class->_collect_return_words($block_words),
                    return_values => $class->_collect_return_values($block),
                    last_stmt     => $last_stmt,
                    last_first    => $last_first,
                };
            }
            # No :Type annotation — skip
        }
        else {
            # Unannotated function: no synthetic type info — gradual typing treats as unconstrained
            my $block = $sub_stmt->block;
            my ($last_stmt, $last_first) = $class->_last_stmt_info($block);
            my $block_words = $class->_collect_block_words($block);
            $result->{functions}{$name} = +{
                unannotated   => 1,
                default_count => $default_count,
                param_names   => $param_names,
                is_method     => $is_method,
                method_kind   => $method_kind,
                line          => $sub_stmt->line_number,
                end_line      => $class->_end_line($sub_stmt),
                col           => $sub_stmt->column_number,
                name_col      => $name_col,
                block         => $block,
                block_words   => $block_words,
                return_words  => $class->_collect_return_words($block_words),
                return_values => $class->_collect_return_values($block),
                last_stmt     => $last_stmt,
                last_first    => $last_first,
            };
        }
    }
}

sub _collect_return_words ($class, $block_or_words = undef) {
    return [] unless $block_or_words;
    my $words = ref $block_or_words eq 'ARRAY'
        ? $block_or_words
        : $class->_collect_block_words($block_or_words);
    [ grep { $_->content eq 'return' } @$words ];
}

sub _collect_return_values ($class, $block) {
    my $returns = $class->_collect_return_words($block);
    my @values;
    for my $ret (@$returns) {
        my $val = $ret->snext_sibling or next;
        next if $val->isa('PPI::Token::Structure') && $val->content eq ';';
        push @values, +{ return_word => $ret, value => $val };
    }
    return \@values;
}

sub _collect_block_words ($class, $block) {
    return [] unless $block;
    return $block->find('PPI::Token::Word') || [];
}

sub _last_stmt_info ($class, $block) {
    return (undef, undef) unless $block;
    my @children = $block->schildren;
    return (undef, undef) unless @children;
    my $last_stmt = $children[-1];
    my $last_first = $last_stmt->schild(0) // $last_stmt;
    return ($last_stmt, $last_first);
}

# ── Loop Compound Parsing ─────────────────────────
#
# Parse a PPI::Statement::Compound into its for-loop components.
# Returns { var_sym, list, block } or undef if not a for/foreach loop.
# PPI structure: Word('for'/'foreach') → Word('my') → Symbol('$item') → List(...) → Block{...}

sub parse_loop_compound ($class, $compound) {
    my @children = $compound->schildren;
    return undef unless @children >= 4;

    my $i = 0;
    return undef unless $children[$i]->isa('PPI::Token::Word')
                     && ($children[$i]->content eq 'for' || $children[$i]->content eq 'foreach');
    $i++;

    return undef unless $children[$i]->isa('PPI::Token::Word')
                     && $children[$i]->content eq 'my';
    $i++;

    return undef unless $children[$i]->isa('PPI::Token::Symbol');
    my $var_sym = $children[$i];
    $i++;

    # Find the List (iterable) and Block (scope)
    my ($list, $block);
    for my $j ($i .. $#children) {
        $list  = $children[$j] if $children[$j]->isa('PPI::Structure::List') && !$list;
        $block = $children[$j] if $children[$j]->isa('PPI::Structure::Block') && !$block;
    }
    return undef unless $list && $block;

    +{ var_sym => $var_sym, list => $list, block => $block };
}

# ── Loop Variable Extraction ─────────────────────

sub _extract_loop_variables ($class, $compounds, $result) {
    for my $stmt (@$compounds) {
        my $parsed = $class->parse_loop_compound($stmt) // next;

        my $var_sym = $parsed->{var_sym};
        my $block   = $parsed->{block};
        my $block_last = $block->last_token;

        push $result->{loop_variables}->@*, +{
            name        => $var_sym->content,
            line        => $var_sym->line_number,
            col         => $var_sym->column_number,
            list_node   => $parsed->{list},
            block_node  => $block,
            scope_start => $block->line_number,
            scope_end   => $block_last ? $block_last->line_number : $block->line_number,
        };
    }
}

# ── Ignore Lines ─────────────────────────────────

# Collect lines suppressed by @typist-ignore comments.
# A comment containing @typist-ignore on line N suppresses diagnostics on line N+1.
sub _collect_ignore_lines ($class, $doc) {
    my $comments = $doc->find('PPI::Token::Comment') || [];
    my %ignored;

    for my $comment (@$comments) {
        next unless $comment->content =~ /\@typist-ignore/;
        $ignored{ $comment->line_number + 1 } = 1;
    }

    \%ignored;
}

# ── Helpers ──────────────────────────────────────

# Collect RHS expression tokens: everything before ';', joining content.
# Single Quote token → ->string (strip quotes). Otherwise join all token contents.
sub _collect_rhs_expr ($class, @children) {
    my @tokens;
    for my $child (@children) {
        last if $child->isa('PPI::Token::Structure') && $child->content eq ';';
        push @tokens, $child;
    }
    return undef unless @tokens;

    # Single Quote token → strip quotes
    if (@tokens == 1 && $tokens[0]->isa('PPI::Token::Quote')) {
        return $tokens[0]->string;
    }

    # Join all token contents, normalizing whitespace
    my $raw = join '', map { $_->content } @tokens;
    $raw =~ s/\A\s+//;
    $raw =~ s/\s+\z//;
    length($raw) ? $raw : undef;
}

# Extract parameter names from a subroutine signature.
# Returns an arrayref of symbol names (e.g., ['$a', '$b']).
# Only considers direct-child Lists of the sub statement (before the block),
# not Lists nested inside the function body.
# Find the signature list PPI node (before the block) in a sub statement.
sub _find_sig_list ($class, $sub_stmt) {
    for my $child ($sub_stmt->schildren) {
        last if $child->isa('PPI::Structure::Block');
        return $child if $child->isa('PPI::Structure::List');
    }
    undef;
}

sub _extract_sig_params ($class, $sub_stmt) {
    my $sig_list = $class->_find_sig_list($sub_stmt) // return [];
    my $inner = $sig_list->find('PPI::Token::Symbol') || [];
    [map { $_->content } @$inner];
}

# Count the number of parameters in a subroutine signature.
sub _count_sig_params ($class, $sub_stmt) {
    scalar $class->_extract_sig_params($sub_stmt)->@*;
}

# Count default parameters in a subroutine signature (params with = expr).
sub _count_sig_defaults ($class, $sub_stmt) {
    my $sig_list = $class->_find_sig_list($sub_stmt) // return 0;

    my $ops = $sig_list->find(sub {
        $_[1]->isa('PPI::Token::Operator') && $_[1]->content eq '='
    }) || [];
    scalar @$ops;
}

# Extract the end line of a subroutine block (last token's line number).
sub _end_line ($class, $sub_stmt) {
    my $block = $sub_stmt->block // return undef;
    my $last = $block->last_token // return undef;
    $last->line_number;
}

# Extract the textual content of a PPI::Structure::List, stripping parens.
sub _list_content ($class, $list) {
    my $raw = $list->content;
    $raw =~ s/\A\(\s*//;
    $raw =~ s/\s*\)\z//;
    length($raw) ? $raw : undef;
}

1;

=head1 NAME

Typist::Static::Extractor - PPI-based type annotation extraction

=head1 DESCRIPTION

Parses Perl source text via L<PPI> and extracts all Typist type annotations
into a structured hashref. This is the first stage of the static analysis
pipeline, producing input for L<Typist::Static::Registration> and
L<Typist::Static::Checker>.

=head2 extract

    my $result = Typist::Static::Extractor->extract($source);

Extracts type annotations from a Perl source string. Returns a hashref with
keys: C<aliases>, C<variables>, C<functions>, C<newtypes>, C<datatypes>,
C<effects>, C<structs>, C<typeclasses>, C<instances>, C<declares>,
C<loop_variables>, C<package>, C<ppi_doc>, and C<ignore_lines>.

=head2 parse_loop_compound

    my $parsed = Typist::Static::Extractor->parse_loop_compound($compound);

Parses a C<PPI::Statement::Compound> node into its for-loop components.
Returns a hashref with keys C<var_sym>, C<list>, and C<block>, or C<undef>
if the compound is not a C<for>/C<foreach> loop. Used by both the Extractor
and L<Typist::Static::TypeChecker> for loop variable inference.

=cut
