defmodule PushX.Message do
  @moduledoc """
  A struct representing a push notification message.

  Provides a builder API for constructing notifications with title, body,
  badge, sound, and custom data.

  ## Examples

      # Simple message
      message = PushX.Message.new("Hello", "World")

      # Builder pattern
      message = PushX.Message.new()
        |> PushX.Message.title("Order Update")
        |> PushX.Message.body("Your order has been shipped!")
        |> PushX.Message.badge(1)
        |> PushX.Message.sound("default")
        |> PushX.Message.data(%{order_id: "12345"})

  """

  @type t :: %__MODULE__{
          title: String.t() | nil,
          body: String.t() | nil,
          badge: non_neg_integer() | nil,
          sound: String.t() | nil,
          data: map(),
          category: String.t() | nil,
          thread_id: String.t() | nil,
          image: String.t() | nil,
          priority: :high | :normal,
          ttl: non_neg_integer() | nil,
          collapse_key: String.t() | nil
        }

  defstruct [
    :title,
    :body,
    :badge,
    :sound,
    :category,
    :thread_id,
    :image,
    :ttl,
    :collapse_key,
    data: %{},
    priority: :high
  ]

  @doc """
  Creates a new empty message.

  ## Examples

      iex> PushX.Message.new()
      %PushX.Message{title: nil, body: nil, data: %{}, priority: :high}

  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new message with title and body.

  ## Examples

      iex> PushX.Message.new("Hello", "World")
      %PushX.Message{title: "Hello", body: "World", data: %{}, priority: :high}

  """
  @spec new(String.t(), String.t()) :: t()
  def new(title, body) do
    %__MODULE__{title: title, body: body}
  end

  @doc """
  Sets the title of the message.
  """
  @spec title(t(), String.t()) :: t()
  def title(%__MODULE__{} = message, title) do
    %{message | title: title}
  end

  @doc """
  Sets the body of the message.
  """
  @spec body(t(), String.t()) :: t()
  def body(%__MODULE__{} = message, body) do
    %{message | body: body}
  end

  @doc """
  Sets the badge count (iOS).
  """
  @spec badge(t(), non_neg_integer()) :: t()
  def badge(%__MODULE__{} = message, badge) when is_integer(badge) and badge >= 0 do
    %{message | badge: badge}
  end

  @doc """
  Sets the notification sound.
  """
  @spec sound(t(), String.t()) :: t()
  def sound(%__MODULE__{} = message, sound) do
    %{message | sound: sound}
  end

  @doc """
  Sets custom data payload.
  """
  @spec data(t(), map()) :: t()
  def data(%__MODULE__{} = message, data) when is_map(data) do
    %{message | data: data}
  end

  @doc """
  Adds a key-value pair to the data payload.
  """
  @spec put_data(t(), atom() | String.t(), any()) :: t()
  def put_data(%__MODULE__{} = message, key, value) do
    %{message | data: Map.put(message.data, key, value)}
  end

  @doc """
  Sets the notification category (iOS).
  """
  @spec category(t(), String.t()) :: t()
  def category(%__MODULE__{} = message, category) do
    %{message | category: category}
  end

  @doc """
  Sets the thread ID for notification grouping (iOS).
  """
  @spec thread_id(t(), String.t()) :: t()
  def thread_id(%__MODULE__{} = message, thread_id) do
    %{message | thread_id: thread_id}
  end

  @doc """
  Sets the image URL for rich notifications.
  """
  @spec image(t(), String.t()) :: t()
  def image(%__MODULE__{} = message, image_url) do
    %{message | image: image_url}
  end

  @doc """
  Sets the priority (:high or :normal).
  """
  @spec priority(t(), :high | :normal) :: t()
  def priority(%__MODULE__{} = message, priority) when priority in [:high, :normal] do
    %{message | priority: priority}
  end

  @doc """
  Sets the TTL (time to live) in seconds.
  """
  @spec ttl(t(), non_neg_integer()) :: t()
  def ttl(%__MODULE__{} = message, ttl) when is_integer(ttl) and ttl >= 0 do
    %{message | ttl: ttl}
  end

  @doc """
  Sets the collapse key for message deduplication.
  """
  @spec collapse_key(t(), String.t()) :: t()
  def collapse_key(%__MODULE__{} = message, key) do
    %{message | collapse_key: key}
  end

  @doc """
  Converts the message to an APNS payload map.
  """
  @spec to_apns_payload(t()) :: map()
  def to_apns_payload(%__MODULE__{} = message) do
    alert =
      %{}
      |> maybe_put("title", message.title)
      |> maybe_put("body", message.body)

    aps =
      %{}
      |> maybe_put("alert", if(alert != %{}, do: alert))
      |> maybe_put("badge", message.badge)
      |> maybe_put("sound", message.sound || if(message.title, do: "default"))
      |> maybe_put("category", message.category)
      |> maybe_put("thread-id", message.thread_id)

    %{"aps" => aps}
    |> Map.merge(Map.delete(message.data, "aps"))
  end

  @doc """
  Converts the message to an FCM payload map.
  """
  @spec to_fcm_payload(t()) :: map()
  def to_fcm_payload(%__MODULE__{} = message) do
    notification =
      %{}
      |> maybe_put("title", message.title)
      |> maybe_put("body", message.body)
      |> maybe_put("image", message.image)

    if notification == %{} do
      %{}
    else
      %{"notification" => notification}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
