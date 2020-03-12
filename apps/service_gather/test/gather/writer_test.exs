defmodule Gather.WriterTest do
  use Gather.Case
  import Mox
  import ExUnit.CaptureLog
  require Temp.Env

  alias Writer.DLQ.DeadLetter

  Temp.Env.modify([
    %{
      app: :service_gather,
      key: Gather.Writer,
      update: fn config ->
        Keyword.put(config, :writer, WriterMock)
        |> Keyword.put(:dlq, DlqMock)
        |> Keyword.put(:kafka_endpoints, localhost: 9092)
      end
    }
  ])

  setup :verify_on_exit!

  describe "start_link/1" do
    test "starts child writer with proper arguments" do
      test = self()

      WriterMock
      |> expect(:start_link, fn args ->
        send(test, {:start_link, args})
      end)

      {:ok, extract} =
        Extract.new(
          version: 1,
          id: "extract-id-1",
          dataset_id: "test-ds1",
          subset_id: "extract_name",
          destination: "topic-1",
          steps: [
            %{
              "step" => "Extract.Http.Get",
              "url" => "http://localhost/file.csv"
            },
            %{
              "step" => "Decode.Csv",
              "headers" => ["A", "B", "C"]
            }
          ],
          config: %{
            "key" => "value"
          }
        )

      Gather.Writer.start_link(extract: extract, name: :joe)

      assert_receive {:start_link, actual}

      assert Keyword.get(actual, :endpoints) == [localhost: 9092]
      assert Keyword.get(actual, :topic) == "topic-1"
      assert Keyword.get(actual, :name) == :joe
      assert Keyword.get(actual, :config) == extract.config

      assert Keyword.get(actual, :metric_metadata) == %{
               app: "service_gather",
               dataset_id: "test-ds1",
               subset_id: "extract_name"
             }
    end
  end

  describe "write/3" do
    setup do
      extract =
        Extract.new!(
          id: "extract-1",
          dataset_id: "ds1",
          subset_id: "sb1",
          destination: "topic-a",
          steps: [],
          dictionary: []
        )

      [extract: extract]
    end

    test "writes message to child writer", %{extract: extract} do
      stub_writer(:ok)

      messages = [
        %{"one" => "two"},
        %{"one" => "three"}
      ]

      :ok = Gather.Writer.write(:pid, messages, extract: extract)

      assert_receive {:write, :pid, actuals}
      assert actuals == Enum.map(messages, &{"", Jason.encode!(&1)})
    end

    test "writes message with proper key", %{extract: extract} do
      stub_writer(:ok)

      messages = [
        %{"spouse" => %{"name" => "joe"}},
        %{"spouse" => %{"name" => "mary"}}
      ]

      assert :ok ==
               Gather.Writer.write(:pid, messages,
                 extract: %{extract | message_key: ["spouse", "name"]}
               )

      assert_receive {:write, :pid, actuals}
      assert actuals == Enum.map(messages, &{get_in(&1, ["spouse", "name"]), Jason.encode!(&1)})
    end

    test "write to DLQ if message cannot be encoded", %{extract: extract} do
      stub_writer(:ok)
      stub_dlq(:ok)

      messages = [
        %{"one" => unencodable_value()},
        %{"one" => "three"}
      ]

      :ok = Gather.Writer.write(:pid, messages, extract: extract)

      assert_receive {:write, :pid, actuals}
      assert actuals = messages |> Enum.at(1) |> Jason.encode!() |> List.wrap()

      assert_receive {:dlq, dead_letters}
      {:error, reason} = messages |> List.first() |> Jason.encode()

      expected =
        DeadLetter.new(
          dataset_id: "ds1",
          subset_id: "sb1",
          original_message: List.first(messages),
          app_name: "service_gather",
          reason: reason
        )
        |> Map.merge(%{stacktrace: nil, timestamp: nil})

      assert [expected] ==
               Enum.map(dead_letters, &Map.merge(&1, %{stacktrace: nil, timestamp: nil}))
    end

    test "only writes to dlq if child writer call succeeds", %{extract: extract} do
      stub_writer({:error, "failure to write"})
      stub_dlq(:ok)

      messages = [
        %{"one" => unencodable_value()},
        %{"one" => "three"}
      ]

      assert {:error, "failure to write"} = Gather.Writer.write(:pid, messages, extract: extract)

      refute_receive {:dlq, _}
    end

    test "dlq returns error tuple", %{extract: extract} do
      stub_dlq({:error, "failure to dlq"})

      messages = [
        %{"one" => unencodable_value()}
      ]

      log =
        capture_log(fn ->
          assert :ok == Gather.Writer.write(:pid, messages, extract: extract)
        end)

      assert log =~
               "Unable to send following messages to DLQ due to 'failure to dlq' :\n%Writer.DLQ.DeadLetter"
    end
  end

  defp stub_writer(return_value) do
    test = self()

    WriterMock
    |> stub(:write, fn server, messages ->
      send(test, {:write, server, messages})
      return_value
    end)
  end

  defp stub_dlq(return_value) do
    test = self()

    DlqMock
    |> stub(:write, fn messages ->
      send(test, {:dlq, messages})
      return_value
    end)
  end

  defp unencodable_value() do
    <<80, 75, 3, 4, 20, 0, 6, 0, 8, 0, 0, 0, 33, 0, 235, 122, 210>>
  end
end
