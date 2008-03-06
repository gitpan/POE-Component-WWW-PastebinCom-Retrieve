#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 5;

my $Test_paste_number = 'f3fdae56d';

use POE qw(Component::WWW::PastebinCom::Retrieve);
my $poco = POE::Component::WWW::PastebinCom::Retrieve->spawn(debug=>1,
timeout => 10);

POE::Session->create(
    inline_states => { _start =>  sub {
           $poco->retrieve( {
                    id => $Test_paste_number,
                    event => 'ret',
                    session => 'other'
                }
            );
        },
    }
);

POE::Session->create(
    package_states => [ main => [qw(_start ret)]],
);

$poe_kernel->run;

sub _start {
    $_[KERNEL]->alias_set('other');
}

sub ret {
    my $in = $_[ARG0];
    is(
        ref $in,
        'HASH',
        '$_[ARG0]',
    );
    SKIP:{
        if ( $in->{error} ) {
            ok( length $in->{error}, 'error must have content' );
            ok( not(exists $in->{content}), 'must not have {content}');
            skip 'got error on paste retrieve', 2;
        }
        ok( not(exists $in->{error}), 'must not have {error}');
        my $content_test = eval "$in->{content}";
        if ( $@ ) {
            die "\n\nPaste content seems to not match what we expected it to..."
                    . " If the paste http://pastebin.com/f3fdae56d exists"
                    . " and contains a Perl hashref, something is wrong"
                    . " with this module. Otherwise it's probably fine to"
                    . " force the instalation";
        }
        ok(
            exists $content_test->{true},
            "keys of evaled paste hashref (key 'true')"
        );
        ok(
            exists $content_test->{false},
            "keys of evaled paste hashref (key 'false')"
        );
        ok(
            exists $content_test->{time},
            "keys of evaled paste hashref (key 'time')"
        );
    }
    $poco->shutdown;
}