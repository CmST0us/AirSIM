// Offline reference vector matching internal/media.NewFrame. No credentials or network.
package main
import ("encoding/binary"; "encoding/hex"; "fmt")
func main() {
    var frame [360]byte
    copy(frame[:4], "ASMP"); frame[4] = 1; frame[5] = 1
    binary.LittleEndian.PutUint16(frame[6:8], 40)
    id, _ := hex.DecodeString("00112233445546778899aabbccddeeff")
    copy(frame[8:24], id); binary.LittleEndian.PutUint64(frame[24:32], 1)
    binary.LittleEndian.PutUint32(frame[32:36], 320)
    for i := 0; i < 320; i++ { frame[40+i] = byte(i) }
    fmt.Printf("%x\n", frame)
}
