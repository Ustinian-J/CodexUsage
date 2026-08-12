namespace CodexS.Windows;

internal sealed class BoundedLineBuffer
{
    internal const int ChunkBytes = 64 * 1024;
    internal const int MaxLineBytes = 1024 * 1024;

    private MemoryStream pending = new();
    private bool discardingOversizedLine;

    internal int BufferedByteCount => checked((int)pending.Length);
    internal bool DiscardingOversizedLine => discardingOversizedLine;

    internal IReadOnlyList<byte[]> Append(ReadOnlySpan<byte> chunk)
    {
        var lines = new List<byte[]>();
        var offset = 0;
        while (offset < chunk.Length)
        {
            var newlineOffset = chunk[offset..].IndexOf((byte)'\n');
            if (newlineOffset < 0)
            {
                AppendSegment(chunk[offset..]);
                break;
            }

            if (!discardingOversizedLine)
                AppendSegment(chunk.Slice(offset, newlineOffset));
            if (!discardingOversizedLine)
            {
                var line = pending.ToArray();
                if (line.Length > 0 && line[^1] == (byte)'\r')
                    Array.Resize(ref line, line.Length - 1);
                if (line.Length > 0) lines.Add(line);
            }

            ClearPending(releaseLargeBuffer: true);
            discardingOversizedLine = false;
            offset += newlineOffset + 1;
        }
        return lines;
    }

    internal void Reset()
    {
        ClearPending(releaseLargeBuffer: true);
        discardingOversizedLine = false;
    }

    private void AppendSegment(ReadOnlySpan<byte> segment)
    {
        if (discardingOversizedLine || pending.Length + segment.Length > MaxLineBytes)
        {
            ClearPending(releaseLargeBuffer: true);
            discardingOversizedLine = true;
            return;
        }
        pending.Write(segment);
    }

    private void ClearPending(bool releaseLargeBuffer)
    {
        if (releaseLargeBuffer && pending.Capacity > ChunkBytes * 2)
        {
            pending.Dispose();
            pending = new MemoryStream();
        }
        else
        {
            pending.SetLength(0);
        }
    }
}
