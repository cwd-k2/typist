package Typist::LSP;
use v5.40;

use Typist::LSP::Server;

sub run ($class) {
    my $server = Typist::LSP::Server->new;
    $server->run;
}

1;
