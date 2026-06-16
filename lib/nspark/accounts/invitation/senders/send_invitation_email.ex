defmodule Nspark.Accounts.Invitation.Senders.SendInvitationEmail do
  @moduledoc "Sends an org invitation email with a one-time accept link."

  use NsparkWeb, :verified_routes
  import Swoosh.Email
  alias Nspark.Mailer

  def deliver(invitation, inviter_email) do
    accept_url = url(~p"/invitations/#{invitation.token}")

    new()
    |> from({"Newtonian Spark", "noreply@example.com"})
    |> to(to_string(invitation.email))
    |> subject("You've been invited to join Newtonian Spark")
    |> html_body(html(invitation, accept_url, inviter_email))
    |> text_body(text(accept_url, inviter_email))
    |> Mailer.deliver!()
  end

  defp html(invitation, url, inviter_email) do
    role = invitation.role |> to_string() |> String.capitalize()

    """
    <p style="font-family: 'IBM Plex Mono', monospace; font-size: 13px; color: #2a2d3a;">
      #{inviter_email} has invited you to join their organization on
      <strong>Newtonian Spark</strong> as a <strong>#{role}</strong>.
    </p>
    <p style="margin-top: 20px;">
      <a href="#{url}"
         style="display: inline-block; padding: 10px 20px; background: oklch(0.5 0.13 255);
                color: white; text-decoration: none; font-family: monospace; font-size: 12px;">
        Accept Invitation →
      </a>
    </p>
    <p style="font-family: monospace; font-size: 11px; color: #666; margin-top: 16px;">
      This link expires in 7 days. If you weren't expecting this, you can ignore it.
    </p>
    """
  end

  defp text(url, inviter_email) do
    """
    #{inviter_email} has invited you to join their organization on Newtonian Spark.

    Accept the invitation here: #{url}

    This link expires in 7 days.
    """
  end
end
