# See bottom of file for default license and copyright information

=begin TML

---+ package Foswiki::Contrib::MailTemplatesContrib

This contrib is meant to handle common tasks when sending mails via plugins.

=cut

package Foswiki::Contrib::MailTemplatesContrib;

use strict;
use warnings;

our $VERSION = '1.0';

our $RELEASE = '1.0';

our $SHORTDESCRIPTION = 'Helper for plugins for sending mails.';

=begin TML

---++ Helper methods

=cut

=begin TML

---+++ listToUsers($list) -> \@usersArray

Convert a string of comma-separated users and groups to an array of users.
   * =$list= - comma-separated list of users and groups

Return: =\@usersArray= array of all users in that list

Each group will be expanded (recursiveley), however each user will be listed
only once, regardless in how often he may appear in the list.

=cut

sub listToUsers {
    my ($list) = @_;

    return unless $list;

    my $users = ();
    $list = Foswiki::Func::expandCommonVariables( $list );
    return unless $list;
    foreach my $entry ( split(',', $list ) ) {
        $entry =~ s#^\s*##;
        $entry =~ s#\s*$##;
        next unless $entry;
        if ( Foswiki::Func::isGroup($entry)) {
            my $it = Foswiki::Func::eachGroupMember($entry);
            while ($it->hasNext()) {
                my $user = $it->next();
                $users->{$user} = 1;
            }
        }
        else {
            $entry = Foswiki::Func::getWikiName($entry);
            $users->{$entry} = 1;
        }
    }
    my @usersArray = keys %$users;
    return unless scalar @usersArray;
    return \@usersArray;
}

=begin TML

---+++ usersToMails($users, $includeCurrent, $skipMails, $skipUsers, $includeUsers) -> \%emails

Transforms a list of users into a hashmap of emails with the associated users.
   * =$users= - arrayref of users
   * =$includeCurrent= - set to true if you want to include the current user
        (you usually do not want to send an email to yourself)
   * =$skipMails= - do not include these email addresses
   * =$skipUsers= - do not include these users
   * =$includeMails= - only include these email addresses
   * =$includeUsers= - only include these users

Return: =\%emails= addresses with their owners

=cut

sub usersToMails {
    my ($users, $includeCurrent, $skipMails, $skipUsers, $includeMails, $includeUsers) = @_;

    return unless $users;

    my $emails = ();
    my $currentUser = Foswiki::Func::getWikiName();
    foreach my $who (@$users) {
        $who =~ s/^.*\.//; # web name?
        $who = Foswiki::Func::getWikiName( $who ); # normalize for comparison
        next if $who eq $currentUser && not $includeCurrent;
        next if defined $skipUsers->{$who};
        next if defined $includeUsers && not defined $includeUsers->{$who};
        my @list = Foswiki::Func::wikinameToEmails($who);
        $skipUsers->{$who} = 1 if scalar @list;
        foreach my $mail ( @list ) {
            next if $skipMails->{$mail};
            next if $includeMails && not $includeMails->{$mail};
            $emails->{$mail} = $who;
            $skipMails->{$mail} = 1;
        }
    }
    return $emails if keys %$emails;
}

=begin TML

---++ Plugin workhorses

These are the methods meant to be called when you want to send an email.

=cut

=begin TML

---+++ sendMail($template, $options)
   * =$template= - name of the template for the mail
   * =$options= - ref to hash of options
     | =IncludeCurrentUser= | Do you want to send yourself an email? |
     | =SingleMail= | if true: join all receipients to a single =To= %BR% otherwise: send a separate mail to each receipient |
     | =beforeSend= | ref to callback function that will be called just before the email will be send out |
     | =beforeSendArgs= | arrayref of arguments to the callback%BR%The text of the mail will be unshiftet to this array |
     | =SkipUsers= | do not send mails to users whose WikiName is in this hashref; any user receiving a mail will be added automatically |
     | =SkipMailUsers= | do not send mails to adresses in this hashref; any adress receiving a mail will be added automatically |
     | =IncludeMailUsers= | only send mails to users whose emails are in this hashref |
     | =IncludeUsers= | only send mails to users whose WikiNames are in this hashref |
     | =id= | entries in logfiles will show this id |

=cut

sub sendMail {
    my ($template, $options) = @_;

    $options ||= {};
    my $includeCurrent = $options->{IncludeCurrentUser};

    Foswiki::Func::loadTemplate($template) if $template;

    my $receipients = ();
    my $skipMails = $options->{SkipMailUsers} || {};
    my $skipUsers = $options->{SkipUsers} || {};
    my $includeUsers = $options->{IncludeUsers};
    my $includeMails = $options->{IncludeMailUsers};

    # Do the generell primer
    Foswiki::Func::expandCommonVariables(Foswiki::Func::expandTemplate( 'ModacMailPrimer' ));

    # get people
    $receipients->{WikiTo} = listToUsers( Foswiki::Func::expandTemplate( 'ModacMailTo' ) );
    $receipients->{WikiCc} = listToUsers( Foswiki::Func::expandTemplate( 'ModacMailCc' ) );
    $receipients->{WikiBcc} = listToUsers( Foswiki::Func::expandTemplate( 'ModacMailBcc' ) );

    # get mails
    $receipients->{To} = usersToMails( $receipients->{WikiTo}, $includeCurrent, $skipMails, $skipUsers, $includeMails, $includeUsers );
    $receipients->{Cc} = usersToMails( $receipients->{WikiCc}, $includeCurrent, $skipMails, $skipUsers, $includeMails, $includeUsers );
    $receipients->{Bcc} = usersToMails( $receipients->{WikiBcc}, $includeCurrent, $skipMails, $skipUsers, $includeMails, $includeUsers );

    return 0 unless $receipients->{To} && scalar keys $receipients->{To};

    # Join to single 'To' field, if requested (otherwise send separate mail to each 'To' mail)
    if( $options->{SingleMail} ) {
        my $mail = '';
        my $wiki = '';
        foreach my $to ( keys $receipients->{To} ) {
            $mail .= ',' if $mail;
            $mail .= $to;
            $wiki .= ', ' if $wiki;
            $wiki .= $receipients->{To}->$to;
        }
        $receipients->{To} = { $mail => $wiki };
    }

    # send mails
    my $count = 1;
    foreach my $to ( keys $receipients->{To} ) {
        Foswiki::Func::setPreferencesValue( 'to_expanded', 'To: '.$to );
        Foswiki::Func::setPreferencesValue( 'to_WikiName', $receipients->{To}->{$to} );
        Foswiki::Func::setPreferencesValue( 'ModacMailCount', $count++ );

        # Do the "each" primer
        Foswiki::Func::expandCommonVariables(Foswiki::Func::expandTemplate( 'ModacMailEachPrimer' ));

        my $text = Foswiki::Func::expandTemplate( "ModacMail" );
        $text = Foswiki::Func::expandCommonVariables( $text );
        $text =~ s#<nop>##g;
        if($options->{beforeSend}) {
            my @args = ((defined $options->{beforeSendArgs})?$options->{beforeSendArgs}:[]);
            unshift (@args, \$text);
            $options->{beforeSend}->(@args);
        }
        unless ($text) {
            Foswiki::Func::writeWarning( "Could not initialize mail".(($options->{id})?" ($options->{id})":'') );
            return;
        }
        if($options->{GenerateOnly}) {
            $options->{GeneratedMails} = [] unless exists $options->{GeneratedMails};
            push(@{$options->{GeneratedMails}}, $text);
        } else {
            my $errors = Foswiki::Func::sendEmail( $text, 5 );
            if ($errors) {
                Foswiki::Func::writeWarning(
                    'Failed to send action mails'.(($options->{id})?" ($options->{id})":'').':'. $errors
                );
            }
        }
    }
}

=begin TML

---++ Command Line Interface

These methods are called from cli when you want to send an email.

=cut

=begin TML

---+++ _sendCli

   * special parameters:
     | =options_...= | Set an option, eg. =options_SingleMail=1= |
     | =includefile_...= | include contents of a file, eg. =includefile_LOG=/home/test/mylog.log= will be made available as =%LOG%= |

=cut

sub _sendCli {
    my $query = Foswiki::Func::getCgiQuery();
    my $template = $query->param('template');

    unless ($template) {
        print STDERR "Please specify template.\n";
        return;
    }

    my $options = { IncludeCurrentUser => 1, SingleMail => 0 };

    # provide cli parameters as preferences/options
    foreach my $param ($query->param) {
        Foswiki::Func::setPreferencesValue($param, $query->param($param));

        # put anything with options prefix into the options hash
        if( $param =~ m/options_(.*Users)$/) {
            # users are a special case; we need to turn them into a hash
            my $paramUsers = $1;
            my $users = $query->param($param);
            if($users) {
                my %hash = ();
                map{ $hash{$_} = 1 } @{listToUsers($users)};
                $options->{$paramUsers} = \%hash;
            }
        } elsif ($param =~ m/options_(.*)/) {
            # anything with options prefix needs to go into the options hash
            my $option = $1;
            $options->{$option} = $query->param($param);
        } elsif ($param =~ m/includefile_(.*)/) {
            # read files and store it as preference
            my $prefName = $1;
            my $fileName = $query->param($param);
            my $val = Foswiki::readFile($fileName);
            Foswiki::Func::setPreferencesValue($prefName, $val);
        }
    }

    # send mail
    my $web = $query->param('web');
    my $topic = $query->param('topic') || $Foswiki::cfg{HomeTopicName};
    ($web, $topic) = Foswiki::Func::normalizeWebTopicName($web, $topic);
    Foswiki::Func::pushTopicContext($web, $topic);
    Foswiki::Contrib::MailTemplatesContrib::sendMail($template, $options);
    Foswiki::Func::popTopicContext();

    if($options->{GenerateOnly} && $options->{GeneratedMails}) {
        print join("\n---NEW MAIL---\n", @{$options->{GeneratedMails}});
    }
}

1;

__END__
Foswiki - The Free and Open Source Wiki, http://foswiki.org/

Copyright (C) 2008-2014 Foswiki Contributors. Foswiki Contributors
are listed in the AUTHORS file in the root of this distribution.
NOTE: Please extend that file, not this notice.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version. For
more details read LICENSE in the root of this distribution.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

As per the GPL, removal of this notice is prohibited.
