#!/usr/bin/env perl
use v5.18;
use warnings;
use Mojo::UserAgent;
use Getopt::Long qw< GetOptions >;
use JSON qw< encode_json >;
use Data::UUID;
use Digest::SHA1 qw< sha1_hex >;

sub is_prime {
    my $n = $_[0];
    for my $k (2..sqrt($n)) {
        return 0 if $n % $k == 0;
    }
    return 1;
}

sub next_prime {
    my $n = $_[0] + 1;
    $n++ while ! is_prime($n);
    return $n;
}

sub encode_utf8 {
    my $s = $_[0] . "";
    utf8::encode($s);
    return $s;
}

sub proof {
    my ($title, $description) = @_;

    my $t = time();
    my $prime = 2;

    my $h = sha1_hex(encode_utf8(join "\n", $title, $description, $t, $prime));
    while ( substr($h,0,4) ne "feed" ) {
        $prime = next_prime($prime);
        $h = sha1_hex(encode_utf8(join "\n", $title, $description, $t, $prime));
    }
    return [ $t, $prime, $h ];
}

sub feedro_create_feed {
    my ($feedro, $title, $description) = @_;
    utf8::decode($title);
    utf8::decode($description);

    my $proof = proof( $title, $description );
    my $ua = Mojo::UserAgent->new();
    my $tx = $ua->post(
        $feedro,
        json => {
            title => $title,
            description => $description,
            proof => $proof,
        }
    );
    my $res = $tx->result;
    say $res->body;
}

my %opts;
GetOptions(
    \%opts,
    "title=s",
    "description=s",
    "feedro=s",
);

die "Requires all off '--title', '--description', and '--feedro'" unless $opts{title} && $opts{description} && $opts{feedro};

feedro_create_feed( $opts{feedro}, $opts{title}, $opts{description} );
