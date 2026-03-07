# Error Handling

Typist provides several complementary approaches to error handling: ADT-based Result/Option types for value-level error tracking, algebraic effects for scoped exception handling, and combinations of both. This page covers each pattern and when to use it.

---

## The Result Type

A `Result[T]` encodes success or failure as a value. The error is part of the return type, so the caller is forced to handle it.

```typist
use v5.40;
use Typist;

BEGIN {
    datatype 'Result[T]' => (
        Ok  => '(T)',
        Err => '(Str)',
    );
}

sub parse_int :sig((Str) -> Result[Int]) ($s) {
    if ($s =~ /\A-?\d+\z/) {
        Ok(int($s));
    } else {
        Err("Not a number: $s");
    }
}
```

### Consuming a Result

Use `match` to handle both arms:

```typist
my $result = parse_int("42");

my $value = match $result,
    Ok  => sub ($n) { $n },
    Err => sub ($msg) { die "Parse failed: $msg\n" };

say $value;    # 42
```

### Chaining Results

For sequential operations that each return a `Result`, extract and re-wrap:

```typist
sub parse_and_double :sig((Str) -> Result[Int]) ($s) {
    my $parsed = parse_int($s);
    match $parsed,
        Ok  => sub ($n) { Ok($n * 2) },
        Err => sub ($msg) { Err($msg) };
}
```

### Result with Typed Errors

For richer error information, use a struct instead of a plain `Str`:

```typist
BEGIN {
    struct ParseError => (
        input   => 'Str',
        message => 'Str',
        optional(position => 'Int'),
    );

    datatype 'ParseResult[T]' => (
        Parsed    => '(T)',
        ParseFail => '(ParseError)',
    );
}

sub parse_csv_field :sig((Str, Int) -> ParseResult[Str]) ($line, $col) {
    my @fields = split /,/, $line;
    if ($col < scalar @fields) {
        Parsed($fields[$col]);
    } else {
        ParseFail(ParseError(
            input    => $line,
            message  => "Column $col out of range",
            position => $col,
        ));
    }
}
```

---

## The Option Type

`Option[T]` models the presence or absence of a value, replacing ad-hoc `undef` checks with a structured type.

```typist
BEGIN {
    datatype 'Option[T]' => (
        Some => '(T)',
        None => '()',
    );
}

sub find_user :sig((Int) -> Option[Str]) ($id) {
    my %users = (1 => "Alice", 2 => "Bob");
    exists $users{$id} ? Some($users{$id}) : None();
}
```

### Consuming an Option

```typist
my $user = find_user(1);

my $name = match $user,
    Some => sub ($n) { $n },
    None => sub { "anonymous" };

say $name;    # "Alice"
```

### Option vs Maybe

Typist also has a built-in `Maybe[T]` type, which is sugar for `T | Undef`. The difference:

| Type | Representation | Pattern matching | Narrowing |
|------|---------------|-----------------|-----------|
| `Maybe[T]` | `T \| Undef` (union) | `defined($x)` check | Control-flow narrowing |
| `Option[T]` | ADT with `Some`/`None` | `match` with arms | Exhaustive match |

Use `Maybe[T]` for simple nullable values where a `defined` check suffices. Use `Option[T]` when you want explicit `match` exhaustiveness and richer composition.

```typist
# Maybe style -- simpler, uses narrowing
sub greet_maybe :sig((Maybe[Str]) -> Str) ($name) {
    if (defined($name)) {
        "Hello, $name!";         # $name narrowed to Str
    } else {
        "Hello, stranger!";
    }
}

# Option style -- explicit match, exhaustive
sub greet_option :sig((Option[Str]) -> Str) ($opt) {
    match $opt,
        Some => sub ($name) { "Hello, $name!" },
        None => sub { "Hello, stranger!" };
}
```

---

## Effect-Based Error Handling

Algebraic effects provide a different approach: errors are declared as effects and handled at the call site, not encoded in return types.

### Using the Built-in Exn Effect

The `Exn` effect bridges Perl's `die` to the handler system:

```typist
sub load_config :sig((Str) -> Str ![Exn]) ($path) {
    open my $fh, '<', $path or die "Cannot open $path: $!\n";
    my $content = do { local $/; <$fh> };
    close $fh;
    $content;
}

my $config = handle {
    load_config("/etc/myapp.conf");
} Exn => +{
    throw => sub ($err) {
        warn "Config error: $err";
        '{}';    # return default config
    },
};
```

### Custom Error Effects

For domain-specific error handling, define your own effect:

```typist
BEGIN {
    effect AppError => +{
        not_found  => '(Str) -> Void',
        forbidden  => '(Str) -> Void',
        validation => '(Str) -> Void',
    };
}

sub get_user :sig((Int) -> Str ![AppError]) ($id) {
    if ($id <= 0) {
        AppError::validation("Invalid user ID: $id");
    }
    my %users = (1 => "Alice", 2 => "Bob");
    unless (exists $users{$id}) {
        AppError::not_found("User $id not found");
    }
    $users{$id};
}
```

### Handling at the Boundary

The caller decides how to handle each error case:

```typist
# In a web handler: map to HTTP responses
my $response = handle {
    my $user = get_user($request_id);
    +{ status => 200, body => $user };
} AppError => +{
    not_found  => sub ($msg) { +{ status => 404, body => $msg } },
    forbidden  => sub ($msg) { +{ status => 403, body => $msg } },
    validation => sub ($msg) { +{ status => 400, body => $msg } },
};

# In a CLI: print and exit
handle {
    my $user = get_user($cli_id);
    say $user;
} AppError => +{
    not_found  => sub ($msg) { die "Error: $msg\n" },
    forbidden  => sub ($msg) { die "Access denied: $msg\n" },
    validation => sub ($msg) { die "Bad input: $msg\n" },
};
```

---

## Combining Result with Effects

Result types and effects are complementary. A function can return a `Result` for expected failures while using effects for infrastructure concerns:

```typist
BEGIN {
    effect DB => +{
        query => '(Str) -> Str',
    };

    effect Logger => +{
        log => '(Str) -> Void',
    };
}

sub find_order :sig((Int) -> Result[Str] ![DB, Logger]) ($id) {
    Logger::log("Looking up order $id");
    my $data = DB::query("SELECT * FROM orders WHERE id = $id");
    if ($data eq '') {
        Err("Order $id not found");
    } else {
        Ok($data);
    }
}
```

The caller handles effects at the boundary while processing results in the business logic:

```typist
my $result = handle {
    handle {
        find_order(42);
    } DB => +{
        query => sub ($sql) { "order_data" },    # real DB call here
    };
} Logger => +{
    log => sub ($msg) { say STDERR $msg },
};

# $result is a Result[Str] -- process it
my $order = match $result,
    Ok  => sub ($data) { $data },
    Err => sub ($msg) { die "Failed: $msg\n" };
```

### Guidelines: Result vs Effect

| Concern | Use Result | Use Effect |
|---------|-----------|-----------|
| Expected domain errors (not found, validation) | Good fit | Works, but heavier |
| Infrastructure concerns (I/O, logging, state) | Awkward | Good fit |
| Caller controls error recovery strategy | Match at call site | Handle at boundary |
| Error must be part of the type signature | Yes (return type) | Yes (effect row) |
| Composing with other errors | Manual chaining | Nested `handle` blocks |

A pragmatic approach: use `Result` for domain-level expected outcomes and effects for cross-cutting infrastructure concerns.

---

## Practical Patterns

### Early Return on Error

```typist
sub process_order :sig((Str) -> Result[Str]) ($raw) {
    my $parsed = parse_int($raw);
    my $id = match $parsed,
        Ok  => sub ($n) { $n },
        Err => sub ($msg) { return Err("Bad order ID: $msg") };

    my $user = find_user($id);
    my $name = match $user,
        Some => sub ($n) { $n },
        None => sub { return Err("Unknown user: $id") };

    Ok("Order for $name");
}
```

### Default Values with Option

```typist
sub user_display :sig((Int) -> Str) ($id) {
    my $user = find_user($id);
    match $user,
        Some => sub ($name) { $name },
        None => sub { "User #$id" };
}
```

### Accumulating Errors

```typist
sub validate_order :sig((Str, Str, Str) -> Result[ArrayRef[Str]]) ($name, $email, $amount) {
    my @errors;
    push @errors, "Name is required"       unless length($name);
    push @errors, "Invalid email"          unless $email =~ /@/;
    push @errors, "Amount must be numeric" unless $amount =~ /\A\d+\z/;

    if (@errors) {
        Err(join('; ', @errors));
    } else {
        Ok([$name, $email, $amount]);
    }
}
```
