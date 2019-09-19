#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;
use Encode qw< encode_utf8 decode_utf8 >;
use Mojo::UserAgent;
use Getopt::Long qw< GetOptions >;
use Digest::SHA1 qw< sha1_hex >;
use JSON;
use Data::UUID;
use XML::Loy;

sub fetch_feed_items {
    my ($url) = @_;

    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->get($url);

    my $body = decode_utf8 $tx->result->body;

    my $xml = XML::Loy->new($body);

    my @rows;
    # rss
    $xml->find("item")->each(
        sub {
            my $el = $_;
            push @rows, {
                title => $el->at("title")->text,
                url   => $el->at("link")->text,
            };
        }
    );

    # atom
    $xml->find("entry")->each(
        sub {
            my $el = $_;
            my %o = (
                title        => $el->at("title"),
                url          => $el->at("link")->attr("href"),
                summary      => $el->at("summary"),
                content_text => $el->at("content"),
            );

            if (!defined($o{content_text}) && defined($o{summary})) {
                $o{content_text} = delete $o{summary};
            }

            for my $k (keys %o) {
                unless (defined $o{$k}) {
                    delete $o{$k};
                    next;
                }

                $o{$k} = $o{$k}->all_text() if ref($o{$k});
                $o{$k} =~ s/\A\s+//;
                $o{$k} =~ s/\s+\z//;
                $o{$k} =~ s/\s+/ /g;
            }

            return unless defined($o{title}) && $o{title} ne '';

            push @rows, \%o;
        }
    );

    my %seen;
    @rows = map {
        $_->{id} = sha1_hex( $_->{url} . "\n" . encode_utf8($_->{title}) );
        $_;
    } grep { !$seen{ $_->{url} } } @rows;

    return \@rows;
}

my %opts;
GetOptions(
    \%opts,
    "from=s",
    "token=s"
);

my $feed_url = $ARGV[0] or die "A feed URL is required.";
$feed_url =~ s{\.json}{/items};

for (qw< from token >) {
    die "`$_` is required.\n" unless $opts{$_};
}

my @items = @{ fetch_feed_items($opts{from}) };

my $ua = Mojo::UserAgent->new;
for my $item (@items) {
    my $tx = $ua->post(
        $feed_url,
        { Authentication => "Bearer $opts{token}" },
        json => $item,
    );
    my $res = $tx->result;

    unless ($res->is_success) {
        say "Error: " . $res->message;
        say "\t" . $res->code;
        say "\t" . $res->body;
    }
}
