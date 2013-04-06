#!/usr/bin/env perl

use 5.16.1;
use warnings;

use XML::Simple;
use DateTime::Format::Strptime;
use HTML::WikiConverter;
use LWP::UserAgent;
use Try::Tiny;
use Digest::MD5 'md5_hex';

die "usage: $0 import_file subdir [branch] | git-fast-import"
   unless @ARGV == 2 or @ARGV == 3;

chomp(my $name = qx(git config --get user.name));
chomp(my $email = qx(git config --get user.email));

my ($file, $subdir, $branch) = @ARGV;

POST:
for my $x (grep $_->{'wp:status'} eq 'publish', @{XMLin($file)->{channel}{item}}) {
   state $date_parser = DateTime::Format::Strptime->new(
      pattern => '%F %T',
      time_zone => 'UTC',
   );

   my $stub = $x =~ m<([^/]+)\/$>
      ? $1
      : lc($x->{title} =~ s/\W/-/gr =~ s/-$//r)
   ;

   my $guid = $x->{guid}{content} || $x->{link};
   utf8::encode($x->{title});
   my $msg = qq($x->{title}\n\nfrom WordPress [$guid]);
   my $timestamp = $date_parser
      ->parse_datetime($x->{'wp:post_date_gmt'})
      ->epoch;

   my $c = $x->{category};
   $c = [$c] if ref $c && ref $c ne 'ARRAY';

   my $content =
      sprintf(qq([[!meta title="%s"]]\n), $x->{title} =~ s/"/\\"/gr) .
      convert_content($x->{'content:encoded'}) . "\n\n" .
      join("\n",
         map '[[!tag ' . s/ /-/r . ']]',
         keys %{
            +{
               map { $_ => 1 }
               grep $_ ne 'uncategorized',
               map $_->{nicename},
               @$c
            }
         }
      );

   say "commit refs/heads/$branch";
   say "committer $name <$email> $timestamp +0000";
   say 'data <<8675309';
   say $msg;
   say '8675309';
   say "M 644 inline $subdir/$stub.mdwn";
   say 'data <<8675309';
   say $content;
   say '8675309';

   get_comments($x->{link}, "$subdir/$stub")
      if $x->{'wp:post_type'} eq 'post'
}

sub get_comments {
   my ($url, $dir) = @_;

   state $ua = LWP::UserAgent->new;

   my $content = $ua->get("$url/feed")->decoded_content;
   my $first;
   my $bail;
   my $decoded =
      try { XMLin($content, ForceArray => ['item']) }
      catch { $bail = 1 };

   return if $bail;

   COMMENT:
   for my $x (@{$decoded->{channel}{item}}) {
      my $date = $x->{pubDate};
      $date =~ s/^\S+\s//;
      $date =~ s/\s\S+$//;

      #ghetto
      $date =~ s/Jan/01/;
      $date =~ s/Feb/02/;
      $date =~ s/Mar/03/;
      $date =~ s/Apr/04/;
      $date =~ s/May/05/;
      $date =~ s/Jun/06/;
      $date =~ s/Jul/07/;
      $date =~ s/Aug/08/;
      $date =~ s/Sep/09/;
      $date =~ s/Oct/10/;
      $date =~ s/Nov/11/;
      $date =~ s/Dec/12/;

      state $date_parser = DateTime::Format::Strptime->new(
         pattern => '%d %m %Y %T',
         time_zone => 'UTC',
      );

      my $datetime = $date_parser
         ->parse_datetime($date);

      my $timestamp = $datetime->epoch;
      my $formatted_date = "$timestamp";

      my $msg = 'Added a comment';
      my $content = convert_content($x->{'content:encoded'});
      utf8::encode($x->{'dc:creator'});

      say "commit refs/heads/$branch";
      # still need to get email address
      say "committer $x->{'dc:creator'} <$x->{'dc:creator'}> $timestamp +0000";
      say 'data <<8675309';
      say $msg;
      say '8675309';
      say "M 644 inline " . unique_comment_location($dir, $content);
      say 'data <<8675309';

      print <<"COMMENT";
[[!comment format=mdwn
 username="$x->{'dc:creator'}"
 date="$formatted_date"
 content="""
$content
"""]]
COMMENT
      say '8675309';
   }
}

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

   $body =~ s(&#(?:8217|039);)(')g;
   $body =~ s(&(?:quot|#822[01]);)(")g;
   $body =~ s(&lt;)(<)g;
   $body =~ s(&gt;)(>)g;
   $body =~ s(&amp;)(&)g;
   $body =~ s(&#8230;)(...)g;
   $body =~ s(&#821[12];)(-)g;
   $body =~ s(&#8216;)(')g;
   $body =~ s(&#8242;)(')g;
   $body =~ s(&infin;)(∞)g;
   #$body =~ s(&#41;)(@)g;
   $body =~ s(&nbsp;)()g;
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

   $converter->html2wiki(join "\n\n", @new_tokens)
}

sub unique_comment_location {
   my ($dir, $content) = @_;

   utf8::encode($content);
   my $md5 = md5_hex($content);

   my $location;
   my $i = 0;
   do {
      $i++;
      $location = "$dir/comment_${i}_$md5._comment";
   } while -e $location;

   return $location
}
