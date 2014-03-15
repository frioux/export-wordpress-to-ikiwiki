#!/usr/bin/env perl

use 5.16.1;
use warnings;

use XML::Simple;
use DateTime::Format::Strptime;
use HTML::WikiConverter;
use DateTime::Format::ISO8601;
use URI;
use Syntax::Keyword::Gather;
use HTML::Entities;

die "usage: $0 import_file subdir [branch] | git-fast-import"
   unless @ARGV == 2 or @ARGV == 3;

chomp(my $name = qx(git config --get user.name));
chomp(my $email = qx(git config --get user.email));

my ($file, $subdir, $branch) = @ARGV;

my %events;

for my $x (grep $_->{'wp:status'} eq 'publish', @{XMLin($file)->{channel}{item}}) {
   warn " -- importing post: $x->{title}\n";
   state $date_parser = DateTime::Format::Strptime->new(
      pattern => '%F %T',
      time_zone => 'America/Chicago',
   );

   my $stub = $x =~ m<([^/]+)\/$>
      ? $1
      : lc($x->{title} =~ s/\W/-/gr =~ s/-+/-/gr =~ s/-$//r =~ s/^-//r)
   ;

   my $guid = $x->{guid}{content} || $x->{link};
   utf8::encode($x->{title});
   my $msg = qq($x->{title}\n\nfrom WordPress [$guid]);
   my $posted_at = $date_parser
      ->parse_datetime($x->{'wp:post_date_gmt'});

   my $timestamp = $posted_at->epoch;

   my $c = $x->{category};
   $c = [$c] if ref $c && ref $c ne 'ARRAY';

   my @tags = sort keys %{
      +{
         map { $_ => 1 }
         grep $_ ne 'uncategorized',
         map $_->{nicename},
         @$c
      }
   };

   my $content = "---\n" .
      sprintf(qq(aliases: ["%s"]\n), URI->new($x->{link})->path) .
      sprintf(qq(title: "%s"\n), $x->{title} =~ s/"/\\"/gr) .
      sprintf(qq(date: "%s"\n), format_tz($posted_at)) .
      (
         @tags
            ? 'tags: [' . (join ', ', map qq("$_"), @tags) . "]\n"
            : ''
      ) .
      (
         $x->{guid}{content}
            ? qq(guid: "$guid"\n)
            : '',
      ) .
      "---\n" .
      convert_content($x->{'content:encoded'});

   $events{$timestamp} = join "\n",
      "commit refs/heads/$branch",
      "committer $name <$email> $timestamp +0000",

      'data <<8675309',
      $msg,
      '8675309',

      "M 644 inline $subdir/$stub.md",
      'data <<8675309',
      $content,
      '8675309',
   ;
}

say $events{$_} for sort keys %events;

sub convert_content {
   my $body = shift;

   utf8::encode($body);

   state $converter = HTML::WikiConverter->new(
      dialect              => 'Markdown',
      link_style           => 'inline',
      unordered_list_style => 'dash',
      image_style          => 'inline',
      image_tag_fallback   => 0,
   );

   # I know I know you can't parse XML with regular expressions.  Go find a real
   # parser and send me a patch
   my $in_code = 0;

   my $start_code = qr(<pre[^>]*>);
   my $end_code = qr(</pre>);

   $body =~ s(http://blog\.afoolishmanifesto\.com)()g;
   $body =~ s(&#(?:8217|039);)(')g;
   $body =~ s(&(?:quot|#822[01]);)(")g;
   $body =~ s(&#8230;)(...)g;
   $body =~ s(&#821[12];)(-)g;
   $body =~ s(&#8216;)(')g;
   $body =~ s(&#8242;)(')g;
   $body =~ s(&infin;)(∞)g;
   #$body =~ s(&#41;)(@)g;
   $body =~ s(&nbsp;)()g;
   decode_entities($body);
   $body =~ s(<code[^>]*>)(<pre>)g;
   $body =~ s(</code>)(</pre>)g;

   my @tokens =
      map {; split qr[(?=<pre>)] }
      map {; split qr[</pre>\K] }
      split /\n\n/,
      $body;

   my @new_tokens;
   for my $t (@tokens) {
      if (
         ($in_code && $t !~ $end_code) ||
         ($t =~ $start_code && $t =~ $end_code)
      ) {
         # do nothing
      } elsif ($t =~ $start_code) {
         $in_code = 1;
      } elsif ($t =~ $end_code) {
         $in_code = 0;
      } else {
         die "$t !!! '$1'" if $t =~ m/&([^;\s]+);/ && $1 !~ /[lg]t/;

         $t = "<p>$t</p>"
      }
      push @new_tokens, $t
   }

   my $converted = $converter->html2wiki(join "\n\n", @new_tokens);
   decode_entities($converted);

   join $/, gather {
      for my $line (split $/, $converted) {
         if ($line =~ m/    /) {
            take $line =~ s/\\([\\_{}*#])/$1/gr
         } else {
            take $line
         }
      }
   }
}

sub format_tz {
   my $dt = shift;

   my $hour_offset = int($dt->offset / 60 / 60);
   if ($hour_offset >= 0) {
      $hour_offset = sprintf("+%02i", $hour_offset)
   } else {
      $hour_offset = sprintf("-%02i", -$hour_offset)
   }
   my $minute_offset = abs($dt->offset / 60 - int($dt->offset / 60 / 60) * 60);

   sprintf '%sT%s%s:%02i', $dt->ymd('-'), $dt->hms(':'), $hour_offset, $minute_offset;
}
