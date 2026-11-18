# frozen_string_literal: true

require "zlib"

# Mechanical XLSX writer for the real scorer reader; contains no narrative.
module StagedSelectionSourcePolicyFixture
  # Write a single-sheet stored ZIP workbook from XML rows; I/O errors propagate.
  def write_workbook(path, sheet, rows)
    entries = {
      "xl/workbook.xml" => %(<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="#{sheet}" sheetId="1" r:id="rId1"/></sheets></workbook>),
      "xl/_rels/workbook.xml.rels" => %(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Target="worksheets/sheet1.xml" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"/></Relationships>),
      "xl/worksheets/sheet1.xml" => %(<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>#{rows.each_with_index.map { |row, index| '<row r="' + (index + 1).to_s + '">' + row.each_with_index.map { |value, column| %(<c r="#{(65 + column).chr}#{index + 1}" t="inlineStr"><is><t>#{value}</t></is></c>) }.join + '</row>' }.join}</sheetData></worksheet>)
    }
    directory = +"".b
    File.open(path, "wb") do |output|
      entries.each do |name, content|
        offset = output.pos
        crc = Zlib.crc32(content)
        output.write([0x04034b50, 20, 0, 0, 0, 0, crc, content.bytesize, content.bytesize, name.bytesize, 0].pack("VvvvvvVVVvv") + name + content)
        directory << [0x02014b50, 20, 20, 0, 0, 0, 0, crc, content.bytesize, content.bytesize, name.bytesize, 0, 0, 0, 0, 0, offset].pack("VvvvvvvVVVvvvvvVV") + name
      end
      offset = output.pos
      output.write(directory)
      output.write([0x06054b50, 0, 0, entries.size, entries.size, directory.bytesize, offset, 0].pack("VvvvvVVv"))
    end
  end
end
