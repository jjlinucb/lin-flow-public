using System.Text.Json.Serialization;

namespace LinFlow.Core;

/// One "what was heard => what you meant" rule from replacements.txt.
///
/// `Id` is the lowercased left-hand side, which is what stops the same rule being learned twice
/// under different casing. `Learned` marks a rule Lin Flow added itself from an edit rather than
/// one typed by hand; it is stored as a trailing "# learned" marker on the line so the file stays
/// hand-editable in a text editor, exactly as on the Mac.
public sealed class Replacement : IEquatable<Replacement>
{
    public string From { get; set; } = "";
    public string To { get; set; } = "";
    public bool Learned { get; set; }

    [JsonIgnore]
    public string Id => From.ToLowerInvariant();

    public Replacement() { }

    public Replacement(string from, string to, bool learned = false)
    {
        From = from;
        To = to;
        Learned = learned;
    }

    public bool Equals(Replacement? other) =>
        other is not null && From == other.From && To == other.To && Learned == other.Learned;

    public override bool Equals(object? obj) => Equals(obj as Replacement);
    public override int GetHashCode() => HashCode.Combine(From, To, Learned);
    public override string ToString() => $"{From} => {To}";
}
