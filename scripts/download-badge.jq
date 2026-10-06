{
  schemaVersion: 1,
  label: "downloads",
  message: ([.[][]
    | select(.draft == false)
    | .assets[]
    | select(.name | ascii_downcase | endswith(".dmg"))
    | .download_count] | add // 0 | tostring),
  color: "44cc11"
}
